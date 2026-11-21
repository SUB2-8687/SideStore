//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents
import UIKit

// Shouldn't conform types we don't own to protocols we don't own, so make custom
// NSError subclass that conforms to CustomLocalizedStringResourceConvertible instead.
//
// Would prefer to just conform ALTLocalizedError to CustomLocalizedStringResourceConvertible,
// but that can't be done without raising minimum version for ALTLocalizedError to iOS 16 :/
@available(iOS 16, tvOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible, @unchecked Sendable
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        let serializedError = (error as NSError).sanitizedForSerialization()
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct InstallIPAIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource = "Install IPA"
    static var description = IntentDescription("Installs an IPA file with SideStore.")
    static var openAppWhenRun = false

    @Parameter(title: "IPA File")
    var ipaFile: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$ipaFile)")
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult
    {
        do
        {
            try await DatabaseManager.shared.start()

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let ipaURL = temporaryDirectory.appendingPathComponent("App.ipa")
            try self.ipaFile.data.write(to: ipaURL)

            let intentProgress = self.progress
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstalledApp, Error>) in
                let group = AppManager.shared.install(.url(ipaURL)) { result in
                    continuation.resume(with: result)
                }
                intentProgress.addChild(group.progress, withPendingUnitCount: 1)
            }

            return .result()
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}


@available(iOS 17.0, tvOS 17.0, *)
extension RefreshAllAppsIntent
{
    private actor OperationActor
    {
        private(set) var operation: BackgroundRefreshAppsOperation?
        
        func set(_ operation: BackgroundRefreshAppsOperation?)
        {
            self.operation = operation
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static let intentClassName = "RefreshAllIntent"
    
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    private let operationActor = OperationActor()
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        // 저전력 모드에서는 백그라운드 작업이 느려지고 빨리 중단되므로,
        // 새로고침이 끝날 때까지 프로세스가 유지되도록 활동/백그라운드 작업을 잡아 둔다.
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "SideStore refresh all apps"
        )
        let backgroundTaskID = await MainActor.run { () -> UIBackgroundTaskIdentifier in
            var taskID = UIBackgroundTaskIdentifier.invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "com.sidestore.RefreshAllAppsIntent") {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return taskID
        }
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            Task { @MainActor in
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        do
        {
            // Request foreground execution at ~27 seconds to gracefully handle timeout.
            // 저전력 모드에서는 CPU/네트워크가 느려 같은 작업도 오래 걸리므로 제한 시간을 늘린다.
            let deadline: ContinuousClock.Instant = .now + .seconds(isLowPowerMode ? 90 : 27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await self.refreshAllApps()
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    throw OperationError.timedOut
                }
                
                do
                {
                    for try await _ in taskGroup.prefix(1)
                    {
                        // We only care about the first child task to complete.
                        taskGroup.cancelAll()
                        break
                    }
                }
                catch OperationError.timedOut
                {
                    // We took too long to finish and return the final result,
                    // so we'll now present a normal notification when finished.
                    let operation = await self.operationActor.operation
                    operation?.presentsFinishedNotification = true
                    
                    // 화면이 잠겨 있거나 자동화로 실행된 경우 포그라운드 전환이 거부될 수 있다.
                    // 예전에는 이 오류 때문에 진행 중이던 새로고침까지 취소되어 단축어가 실패했으므로,
                    // 전환에 실패해도 새로고침은 계속 진행하고 끝날 때까지 기다린다.
                    do
                    {
                        try await self.requestToContinueInForeground()
                    }
                    catch
                    {
                        debugLog("[RefreshAllAppsIntent] requestToContinueInForeground failed; continuing refresh in background. \(error)")
                    }
                }
            }
            
            return .result(dialog: "All apps have been refreshed.")
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async throws
    {
        try await DatabaseManager.shared.start()
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        try await withCheckedThrowingContinuation { continuation in
            let operation = try? AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: self.presentsNotifications) { (result) in
                do
                {
                    let results = try result.get()
                    
                    for (_, result) in results
                    {
                        guard case let .failure(error) = result else { continue }
                        throw error
                    }
                    
                    continuation.resume()
                }
                catch OperationError.noInstalledApps
                {
                    continuation.resume()
                }
                catch
                {
                    continuation.resume(throwing: error)
                }
            }
            
            guard let operation else {
                debugLog("[RefreshAllAppsIntent] backgroundRefresh instance is nil")
                return 
            }
            
            operation.ignoresServerNotFoundError = false
            
            self.progress.addChild(operation.progress, withPendingUnitCount: 1)
            
            Task {
                await self.operationActor.set(operation)
            }
        }
    }
}

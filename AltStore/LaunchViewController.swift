//
//  LaunchViewController.swift
//  AltStore
//
//  Created by Riley Testut on 7/30/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

import SideSign
import UniformTypeIdentifiers
import CryptoKit
import SwiftUI

final class LaunchViewController: UIViewController {
    private var didFinishLaunching = false
    private var retries = 0
    private var maxRetries = 3
    private var splashViewModel = SplashViewModel()
    private var destinationViewController: TabBarController?
    private var startTime: Date!
    private var languageObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        debugLog("[LaunchViewController] viewDidLoad()")

        // 설정에서 앱 언어를 바꾸면 재실행 없이 즉시 메인 화면을 새 언어로 다시 구성한다.
        languageObserver = NotificationCenter.default.addObserver(
            forName: LanguageManager.languageDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadMainInterfaceForLanguageChange()
            }
        }
        destinationViewController = storyboard!.instantiateViewController(withIdentifier: "tabBarController") as? TabBarController

        #if !os(tvOS)
            if !UserDefaults.standard.hasCompletedOnboarding {
                let hostingController = UIHostingController(rootView: OnboardingView { [weak self] in
                    Task { @MainActor in
                        self?.transitionToMainInterface()
                    }
                })
                embed(child: hostingController)
                return
            }
        #endif

        let splashHosting = UIHostingController(rootView: SplashView(viewModel: splashViewModel))
        embed(child: splashHosting)
    }

    /// 언어 변경 시 스토리보드 문자열(탭 이름, 설정 화면 정적 셀 등)을 새 언어로 다시 읽어야 하므로
    /// TabBarController 는 새로 만들어야 한다(스토리보드 문자열은 로드 시점에만 번들에서 조회됨).
    /// 다만 사용자 눈에는 아무 전환도 보이지 않도록 다음을 보장한다.
    ///  - 새 화면을 옛 화면 위에 먼저 올린 뒤 옛 화면을 제거 (빈 프레임/깜빡임 없음)
    ///  - 모든 교체를 비애니메이션(performWithoutAnimation + CATransaction)으로 수행
    ///  - '사용자 지정 항목' 화면은 새로 만들지 않고 기존 UIHostingController 인스턴스를 그대로 재사용
    ///    (SwiftUI 상태/스크롤 위치 유지, push 슬라이드 애니메이션 없음)
    ///  - 선택된 탭, 설정 목록 스크롤 위치 복원
    @MainActor
    private func reloadMainInterfaceForLanguageChange() {
        guard let oldTab = destinationViewController,
              oldTab.parent === self,
              let newTab = storyboard?.instantiateViewController(withIdentifier: "tabBarController") as? TabBarController
        else { return }

        func settingsNav(of tab: UITabBarController) -> UINavigationController? {
            tab.viewControllers?
                .compactMap { $0 as? UINavigationController }
                .first { $0.viewControllers.first is SettingsViewController }
        }

        let selectedIndex = oldTab.selectedIndex
        let oldSettingsNav = settingsNav(of: oldTab)
        let oldSettingsVC = oldSettingsNav?.viewControllers.first as? SettingsViewController
        let savedOffset = oldSettingsVC?.tableView.contentOffset

        // 사용자 지정 항목 화면(SwiftUI)을 보고 있었다면 인스턴스를 그대로 가져온다.
        var reusableHosting: UIViewController?
        if let nav = oldSettingsNav,
           let root = nav.viewControllers.first,
           let top = nav.topViewController,
           top is UIHostingController<UserCustomizationsView> {
            reusableHosting = top
            // 옛 네비게이션 스택에서 분리 (애니메이션 없이)
            nav.setViewControllers([root], animated: false)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            newTab.selectedIndex = selectedIndex
            destinationViewController = newTab
            embed(child: newTab)          // 새 화면을 먼저 위에 올린다.
            InterfaceLocalizer.shared.localizeTree(newTab)   // 스토리보드 문자열을 앱 언어로
            self.view.layoutIfNeeded()

            if let hosting = reusableHosting,
               let nav = settingsNav(of: newTab),
               let settingsVC = nav.viewControllers.first {
                nav.setViewControllers([settingsVC, hosting], animated: false)
            }

            if let offset = savedOffset,
               let settingsVC = settingsNav(of: newTab)?.viewControllers.first as? SettingsViewController {
                settingsVC.loadViewIfNeeded()
                settingsVC.tableView.layoutIfNeeded()
                settingsVC.tableView.setContentOffset(offset, animated: false)
            }

            // 옛 화면 제거 (새 화면이 이미 덮고 있으므로 깜빡임 없음)
            oldTab.willMove(toParent: nil)
            oldTab.view.removeFromSuperview()
            oldTab.removeFromParent()
        }
        CATransaction.commit()
    }

    @MainActor
    private func embed(child: UIViewController) {
        child.loadViewIfNeeded()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        child.didMove(toParent: self)

        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        debugLog("LaunchViewController.viewDidAppear() invoked")
        super.viewDidAppear(animated)
        guard !didFinishLaunching else { return }
        startTime = Date()
        splashViewModel.updateStatus(NSLocalizedString("Starting…", comment: ""))
        
        // spin off the startup sequence concurrently
        Task.detached { [weak self] in
            await self?.runLaunchSequence()
        }
        Task.detached { [weak self] in
            await self?.doPostLaunch()
        }
    }

    private nonisolated func runLaunchSequence() async {
        guard await retries < maxRetries else { return }
        await MainActor.run{
            retries += 1
        }
        do {
            try await DatabaseManager.shared.start()
            await self.finishLaunching()
        } catch {
            await self.handleLaunchError(error, retryCallback: self.runLaunchSequence)
        }
    }

    private nonisolated func doPostLaunch() async {
        #if !targetEnvironment(simulator)
        await detectAndImportAccountFile()
        #endif
    }

    @MainActor
    func displayError(_ msg: String) {
        debugLog("[SideStore] \(msg)")
        let alert = UIAlertController(title: NSLocalizedString("Error launching SideStore", comment: ""), message: msg, preferredStyle: .alert)
        self.present(alert, animated: true)
    }
    
    func detectAndImportAccountFile() {
        let accountFileURL = FileManager.default.documentsDirectory.appendingPathComponent(AppConstants.accountConfigurationFileName)
        guard FileManager.default.fileExists(atPath: accountFileURL.path) else { return }
        guard let data = try? Data(contentsOf: accountFileURL) else { return }
        
        let checksum = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        guard checksum != UserDefaults.standard.acctFileChecksum else {
            debugLog("[LaunchViewController] Skipping import for \(accountFileURL.lastPathComponent): checksum unchanged.")
            return
        }

        let alert = ImportAccountAlertController.make(data: data, checksum: checksum, presentingViewController: self)
        self.present(alert, animated: true)
    }

    @MainActor
    func handleLaunchError(_ error: Error, retryCallback: (() async -> Void)? = nil) {
        let (title, message, extraActions) = self.parseLaunchErrorDetails(error, retryCallback: retryCallback)

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        extraActions.forEach { alert.addAction($0) }
        alert.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
            Task { await retryCallback?() }
        })
        present(alert, animated: true)
    }

    @MainActor
    private func parseLaunchErrorDetails(_ error: Error, retryCallback: (() async -> Void)?) -> (title: String, message: String, extraActions: [UIAlertAction]) {
        if let dbError = error as? DatabaseError {
            switch dbError {
            case .databaseDowngradeDetected(let reason):
                let resetAction = UIAlertAction(title: NSLocalizedString("Reset Database", comment: ""), style: .destructive) { [weak self] _ in
                    DatabaseManager.recreateDatabase()
                    Task {
                        await MainActor.run { self?.retries = 0 }
                        await retryCallback?()
                    }
                }
                return (
                    title: dbError.errorDescription ?? NSLocalizedString("Database Downgrade Detected", comment: ""),
                    message: reason,
                    extraActions: [resetAction]
                )
            case .missingAppGroup(let reason), .migrationFailed(let reason):
                return (
                    title: dbError.errorDescription ?? NSLocalizedString("Database Error", comment: ""),
                    message: reason,
                    extraActions: []
                )
            }
        }

        let nsError = error as NSError
        let title = nsError.userInfo[NSLocalizedFailureErrorKey] as? String ?? NSLocalizedString("Unable to Launch SideStore", comment: "")
        let desc = ([nsError.debugDescription] + nsError.underlyingErrors.map { ($0 as NSError).debugDescription }).joined(separator: "\n\n")
        return (title: title, message: desc, extraActions: [])
    }

    @MainActor
    func finishLaunching() async {
        guard !didFinishLaunching else { return }

        #if !os(tvOS)
            if !UserDefaults.standard.hasCompletedOnboarding {
                await AppManager.shared.reconcileInstalledApps()
                AppManager.shared.updateAllSources { _ in }
                updateKnownSources()
                didFinishLaunching = true
                return
            }
        #endif

        didFinishLaunching = true
        
        splashViewModel.updateStatus(NSLocalizedString("Loading apps…", comment: ""))
        await AppManager.shared.reconcileInstalledApps()
        splashViewModel.updateStatus(NSLocalizedString("Updating sources…", comment: ""))
        AppManager.shared.updateAllSources { result in
            guard case .failure(let error) = result else { return }
            debugLog("Failed to update sources on launch. \(error.localizedDescription)")
            
            let errorDesc = ErrorProcessing(.fullError).getDescription(error: error as NSError)
            debugLog("Failed to update sources on launch. \(errorDesc)")
            
            let toastView = ToastView(text: NSLocalizedString("Some sources were unable to load", comment: ""), detailText: nil)
            toastView.addTarget(self.destinationViewController, action: #selector(TabBarController.presentSources), for: .touchUpInside)
            toastView.show(in: self.destinationViewController!.selectedViewController ?? self.destinationViewController!)
        }
        updateKnownSources()
        splashViewModel.updateStatus(NSLocalizedString("Almost there…", comment: ""))

        let elapsed = abs(startTime.timeIntervalSinceNow)
        let remaining = elapsed >= 1 ? 0 : 1 - elapsed
        try? await Task.sleep(nanoseconds: UInt64(remaining * 500_000_000))

        transitionToMainInterface()
    }

    @MainActor
    private func transitionToMainInterface() {
        let destinationVC = destinationViewController!

        embed(child: destinationVC)

        // Set initial alpha for fade-in
        destinationVC.view.alpha = 0

        UIView.transition(with: view, duration: 0.3, options: .transitionCrossDissolve) { [self] in
            for child in self.children where child !== destinationVC {
                child.view.alpha = 0
            }

            destinationVC.view.alpha = 1
        } completion: { [self] _ in
            debugLog("[LaunchViewController] Transition complete - exiting LaunchViewController, handing off to TabBarController")
            for child in self.children where child !== destinationVC {
                child.willMove(toParent: nil)
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
            self.destinationViewController = destinationVC
            
            Task.detached { @MainActor [weak self] in
                guard let self = self else { return }
                if AppBootManager.shared.needsPairingPrompt {
                    await AppBootManager.shared.promptForPairing(on: self)
                }
                
                if AppBootManager.shared.needsSideJITPrompt {
                    SideJITManager.shared.presentJITPrompt(presentingVC: self)
                }
            }
        }
    }

    func updateKnownSources() {
        AppManager.shared.updateKnownSources { result in
            switch result {
            case .failure(let error): debugLog("[SideStore] Failed to update known sources: \(error)")
            case .success((_, let blockedSources)):
                DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                    let blockedSourceIDs = Set(blockedSources.lazy.map { $0.identifier })
                    let blockedSourceURLs = Set(blockedSources.lazy.compactMap { $0.sourceURL })
                    let predicate = NSPredicate(format: "%K IN %@ OR %K IN %@", #keyPath(Source.identifier), blockedSourceIDs, #keyPath(Source.sourceURL), blockedSourceURLs)
                    let sourceErrors = Source.all(satisfying: predicate, in: context).map { source in
                        let blocked = blockedSources.first { $0.identifier == source.identifier }
                        return SourceError.blocked(source, bundleIDs: blocked?.bundleIDs, existingSource: source)
                    }
                    guard !sourceErrors.isEmpty else { return }
                    Task {
                        for error in sourceErrors {
                            let title = String(format: NSLocalizedString("“%@” Blocked", comment: ""), error.$source.name)
                            let message = [error.localizedDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
                            await self.presentAlert(title: title, message: message)
                        }
                    }
                }
            }
        }
    }
}

//
//  AppIDsListView.swift
//  SideStore
//
//  Created by Magesh K on 2/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import SideSign

struct AppIDsListView: View {
    @ObservedObject var viewModel: DeveloperServicesViewModel
    weak var presentingViewController: UIViewController?

    @State private var searchText = ""
    @State private var showRegisterSheet = false
    @State private var newAppIDName = ""
    @State private var newAppIDBundleID = ""

    @State private var appIDToDelete: ALTAppID? = nil
    @State private var showDeleteConfirmation = false

    private var filteredAppIDs: [ALTAppID] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.appIDs
        }
        return viewModel.appIDs.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText) ||
            $0.identifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section(header: Text(String(format: localizedString("Registered App IDs (%d)"), viewModel.appIDs.count))) {
                if filteredAppIDs.isEmpty {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text(searchText.isEmpty ? localizedString("No App IDs registered on Developer Portal.") : localizedString("No matching App IDs found."))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } else {
                    ForEach(filteredAppIDs, id: \.identifier) { appID in
                        NavigationLink(destination: AppIDDetailView(appID: appID, viewModel: viewModel, presentingViewController: presentingViewController)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(appID.name.isEmpty ? localizedString("App ID") : appID.name)
                                        .font(.headline)
                                    Spacer()
                                    if !appID.features.isEmpty {
                                        Text(String(format: localizedString("%d features"), appID.features.count))
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .foregroundColor(.accentColor)
                                            .cornerRadius(6)
                                    }
                                }
                                Text(appID.bundleIdentifier)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Text(String(format: localizedString("ID: %@"), appID.identifier))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if let expiration = appID.expirationDate {
                                        Text(String(format: localizedString("Expires: %@"), formatDate(expiration)))
                                            .font(.caption)
                                            .foregroundColor(expiration < Date() ? .red : .secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        #if !os(tvOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            SwiftUI.Button(role: .destructive) {
                                appIDToDelete = appID
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        #endif
                        .contextMenu {
                            SwiftUI.Button(role: .destructive) {
                                appIDToDelete = appID
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        #if !os(tvOS)
        .listStyle(InsetGroupedListStyle())
         .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: localizedString("Search App IDs"))
        #else
        .listStyle(GroupedListStyle())
        #endif
        .navigationTitle(localizedString("App IDs"))
        .appLanguageEnvironment()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button {
                    showRegisterSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await viewModel.fetchAppIDs(presentingViewController: presentingViewController, isPullToRefresh: true)
        }
        .sheet(isPresented: $showRegisterSheet) {
            NavigationView {
                Form {
                    Section(header: Text(localizedString("App ID Information")), footer: Text(localizedString("Bundle ID must match reverse-DNS format (e.g. com.example.myapp)."))) {
                        TextField(localizedString("Name (e.g. My App)"), text: $newAppIDName)
                        TextField(localizedString("Bundle Identifier"), text: $newAppIDBundleID)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .navigationTitle(localizedString("Register App ID"))
                .appLanguageEnvironment()
                .navigationBarItems(
                    leading: SwiftUI.Button(localizedString("Cancel")) {
                        newAppIDName = ""
                        newAppIDBundleID = ""
                        showRegisterSheet = false
                    },
                    trailing: SwiftUI.Button(localizedString("Register")) {
                        let name = newAppIDName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let bundleID = newAppIDBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !bundleID.isEmpty else { return }
                        Task {
                            let success = await viewModel.createAppID(name: name, bundleIdentifier: bundleID, presentingViewController: presentingViewController)
                            if success {
                                newAppIDName = ""
                                newAppIDBundleID = ""
                                showRegisterSheet = false
                            }
                        }
                    }
                    .disabled(newAppIDName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newAppIDBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              viewModel.isActionLoading)
                )
            }
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text(viewModel.isPaidAccount ? localizedString("Delete App ID?") : localizedString("Warning: Delete App ID?")),
                message: Text(deleteAlertMessage),
                primaryButton: .destructive(Text(localizedString("Delete"))) {
                    if let target = appIDToDelete {
                        Task {
                            _ = await viewModel.deleteAppID(target, presentingViewController: presentingViewController)
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .developerServicesToast(viewModel: viewModel)
    }

    private var deleteAlertMessage: String {
        guard let appID = appIDToDelete else { return "" }
        let name = appID.name.isEmpty ? localizedString("this App ID") : "'\(appID.name)'"
        let bundleID = appID.bundleIdentifier.isEmpty ? "" : " (\(appID.bundleIdentifier))"

        if viewModel.isPaidAccount {
            return String(format: localizedString("Are you sure you want to delete %@%@? This will also remove any associated provisioning profiles."), name, bundleID)
        }

        if let expiration = appID.expirationDate {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day], from: Date(), to: expiration)
            if let days = components.day, days > 0 {
                return String(format: localizedString("Warning: Deleting %1$@%2$@ does not free up an App ID slot.\n\nThis App ID will become reserved and will not be available for use until it expires automatically in %3$d day(s) (from its usual 7-day validity).\n\nAre you sure you want to delete it?"), name, bundleID, days)
            }
        }

        return String(format: localizedString("Warning: Deleting %@%@ does not free up an App ID slot.\n\nThis App ID will become reserved and will not be available for use until it expires automatically after the remaining days of its usual 7-day validity.\n\nAre you sure you want to delete it?"), name, bundleID)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = AppDateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

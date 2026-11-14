//
//  AppGroupsListView.swift
//  SideStore
//
//  Created by Magesh K on 2/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import SideSign

struct AppGroupsListView: View {
    @ObservedObject var viewModel: DeveloperServicesViewModel
    weak var presentingViewController: UIViewController?

    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var newGroupName = ""
    @State private var newGroupIdentifier = "group."

    @State private var groupToEdit: ALTAppGroup? = nil
    @State private var editGroupName = ""
    @State private var showSheetDeleteConfirmation = false

    @State private var groupToDelete: ALTAppGroup? = nil
    @State private var showDeleteConfirmation = false

    private var filteredGroups: [ALTAppGroup] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.appGroups
        }
        return viewModel.appGroups.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.groupIdentifier.localizedCaseInsensitiveContains(searchText) ||
            $0.identifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section(header: Text(String(format: localizedString("App Groups (%d)"), viewModel.appGroups.count)), footer: Text(localizedString("App Groups enable data sharing across multiple apps and extensions within the same developer team. Tap a group to edit its name or delete it."))) {
                if filteredGroups.isEmpty {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text(searchText.isEmpty ? localizedString("No App Groups found on Developer Portal.") : localizedString("No matching App Groups found."))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } else {
                    ForEach(filteredGroups, id: \.identifier) { group in
                        SwiftUI.Button {
                            editGroupName = group.name
                            groupToEdit = group
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(group.name.isEmpty ? localizedString("App Group") : group.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(group.groupIdentifier)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Text(String(format: localizedString("Group ID: %@"), group.identifier))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        #if !os(tvOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            SwiftUI.Button(role: .destructive) {
                                groupToDelete = group
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            SwiftUI.Button {
                                editGroupName = group.name
                                groupToEdit = group
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        #endif
                        .contextMenu {
                            SwiftUI.Button {
                                editGroupName = group.name
                                groupToEdit = group
                            } label: {
                                Label("Edit Name", systemImage: "pencil")
                            }
                            #if !os(tvOS)
                            SwiftUI.Button {
                                UIPasteboard.general.string = group.groupIdentifier
                            } label: {
                                Label("Copy Identifier", systemImage: "doc.on.doc")
                            }
                            #endif
                            SwiftUI.Button(role: .destructive) {
                                groupToDelete = group
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
         .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: localizedString("Search App Groups"))
        #else
        .listStyle(GroupedListStyle())
        #endif
        .navigationTitle(localizedString("App Groups"))
        .appLanguageEnvironment()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button {
                    newGroupName = ""
                    newGroupIdentifier = "group."
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await viewModel.fetchAppGroups(presentingViewController: presentingViewController, isPullToRefresh: true)
        }
        .sheet(isPresented: $showCreateSheet) {
            NavigationView {
                Form {
                    Section(header: Text(localizedString("App Group Details")), footer: Text(localizedString("Group identifier must start with 'group.' prefix (e.g. group.com.example.shared)."))) {
                        TextField(localizedString("Name (e.g. Shared Storage)"), text: $newGroupName)
                        TextField(localizedString("Group Identifier"), text: $newGroupIdentifier)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .navigationTitle(localizedString("Create App Group"))
                .appLanguageEnvironment()
                .navigationBarItems(
                    leading: SwiftUI.Button(localizedString("Cancel")) {
                        showCreateSheet = false
                    },
                    trailing: SwiftUI.Button(localizedString("Create")) {
                        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let groupID = newGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !groupID.isEmpty else { return }
                        Task {
                            let success = await viewModel.createAppGroup(name: name, groupIdentifier: groupID, presentingViewController: presentingViewController)
                            if success {
                                showCreateSheet = false
                            }
                        }
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newGroupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !newGroupIdentifier.hasPrefix("group.") ||
                              viewModel.isActionLoading)
                )
            }
        }
        .sheet(item: $groupToEdit) { group in
            NavigationView {
                Form {
                    Section(header: Text(localizedString("Description")), footer: Text(localizedString("You cannot use special characters such as @, &, *, ', \", -, ."))) {
                        TextField(localizedString("Description"), text: $editGroupName)
                    }

                    Section(header: Text(localizedString("Identifier"))) {
                        Text(group.groupIdentifier)
                            .foregroundColor(.secondary)
                    }

                    Section {
                        SwiftUI.Button(role: .destructive) {
                            showSheetDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "trash")
                                Text(localizedString("Remove App Group"))
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }
                .navigationTitle(localizedString("Edit Identifier Configuration"))
                .appLanguageEnvironment()
                .navigationBarItems(
                    leading: SwiftUI.Button(localizedString("Cancel")) {
                        groupToEdit = nil
                    },
                    trailing: SwiftUI.Button(localizedString("Save")) {
                        let trimmed = editGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            let success = await viewModel.updateAppGroup(group, newName: trimmed, presentingViewController: presentingViewController)
                            if success {
                                groupToEdit = nil
                            }
                        }
                    }
                    .disabled(editGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              editGroupName == group.name ||
                              viewModel.isActionLoading)
                )
                .alert(isPresented: $showSheetDeleteConfirmation) {
                    Alert(
                        title: Text(localizedString("Delete App Group?")),
                        message: Text(String(format: localizedString("Are you sure you want to delete '%@' (%@) from Apple Developer Portal?"), group.name, group.groupIdentifier)),
                        primaryButton: .destructive(Text(localizedString("Delete"))) {
                            Task {
                                let success = await viewModel.deleteAppGroup(group, presentingViewController: presentingViewController)
                                if success {
                                    groupToEdit = nil
                                }
                            }
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text(localizedString("Delete App Group?")),
                message: Text(String(format: localizedString("Are you sure you want to delete '%@' (%@) from Apple Developer Portal?"), groupToDelete?.name ?? "this App Group", groupToDelete?.groupIdentifier ?? "")),
                primaryButton: .destructive(Text(localizedString("Delete"))) {
                    if let target = groupToDelete {
                        Task {
                            _ = await viewModel.deleteAppGroup(target, presentingViewController: presentingViewController)
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .developerServicesToast(viewModel: viewModel)
    }
}

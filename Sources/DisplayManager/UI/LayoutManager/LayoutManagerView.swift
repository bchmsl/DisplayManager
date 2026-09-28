import DisplayManagerCore
import SwiftUI

/// The Layout Manager window: Current Displays and saved layouts in the sidebar, details on the right.
struct LayoutManagerView: View {
    let model: AppModel
    let coordinator: WindowCoordinator
    @Bindable var state: ManagerState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    coordinator.saveCurrentLayout()
                } label: {
                    Label("Save Current Layout…", systemImage: "plus")
                }
                .help("Save Current Layout…")
                .disabled(!model.displayplacerStatus.isUsable)

                Menu {
                    Button("Import…") { coordinator.importLayouts() }
                    Button("Export All…") { coordinator.exportLayouts() }
                        .disabled(model.profiles.isEmpty)
                } label: {
                    Label("Import and Export", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Import or export layouts")
            }
        }
        .onChange(of: model.profiles.map(\.id)) { _, ids in
            if case .profile(let id) = state.selection, !ids.contains(id) {
                state.selection = .currentDisplays
            }
        }
    }

    private var sidebar: some View {
        List(selection: $state.selection) {
            Label("Current Displays", systemImage: "display.2")
                .tag(SidebarItem.currentDisplays)

            Section("Layouts") {
                if model.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No layouts yet").foregroundStyle(.secondary)
                        Button("Save Current Layout…") { coordinator.saveCurrentLayout() }
                            .disabled(!model.displayplacerStatus.isUsable)
                    }
                    .padding(.vertical, 4)
                    .selectionDisabled()
                }
                ForEach(model.profiles) { profile in
                    ProfileSidebarRow(model: model, profile: profile)
                        .tag(SidebarItem.profile(profile.id))
                        .contextMenu { contextMenu(for: profile) }
                }
                .onMove { source, destination in
                    model.moveProfiles(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func contextMenu(for profile: LayoutProfile) -> some View {
        Button("Apply") { coordinator.apply(profile.id) }
            .disabled(model.unavailableReason(for: profile) != nil)
        Button("Rename…") { coordinator.renameProfile(profile.id) }
        Button("Duplicate") { coordinator.duplicateProfile(profile.id) }
        Button("Export…") { coordinator.exportLayouts(profileIDs: [profile.id]) }
        Divider()
        Button("Delete…", role: .destructive) { coordinator.deleteProfile(profile.id) }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .profile(let id):
            ProfileDetailView(model: model, coordinator: coordinator, profileID: id)
                .id(id)
        case .currentDisplays, nil:
            CurrentDisplaysView(model: model, coordinator: coordinator)
        }
    }
}

private struct ProfileSidebarRow: View {
    let model: AppModel
    let profile: LayoutProfile

    private var isActive: Bool { model.currentProfileID == profile.id }

    var body: some View {
        HStack(spacing: 6) {
            Label(profile.name, systemImage: "rectangle.3.group")
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.rule(for: profile.id)?.isEnabled == true {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.secondary)
                    .help("Auto Apply is on for this layout")
            }
            if let shortcut = profile.shortcut {
                Text(shortcut.displayString).font(.caption).foregroundStyle(.secondary)
            }
            if model.lastResults[profile.id]?.succeeded == false {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("The last apply failed")
            }
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Current layout")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? "\(profile.name), current layout" : profile.name)
    }
}

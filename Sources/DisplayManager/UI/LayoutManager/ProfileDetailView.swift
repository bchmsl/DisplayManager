import DisplayManagerCore
import SwiftUI

struct ProfileDetailView: View {
    let model: AppModel
    let coordinator: WindowCoordinator
    let profileID: UUID

    var body: some View {
        if let profile = model.profile(id: profileID) {
            ProfileDetailContent(model: model, coordinator: coordinator, profile: profile)
        } else {
            ContentUnavailableView("Layout not found", systemImage: "questionmark.square.dashed")
        }
    }
}

private struct ProfileDetailContent: View {
    let model: AppModel
    let coordinator: WindowCoordinator
    let profile: LayoutProfile

    @State private var name = ""
    @State private var nameProblem: String?
    @State private var showsRawCommand = false
    @FocusState private var nameFocused: Bool

    private var resolution: DisplayResolution? {
        model.snapshot.map { DisplayResolver.resolve(profile: profile, snapshot: $0) }
    }

    /// Saved ids whose display is connected now (the preview draws the others dashed).
    private var connectedSavedIDs: Set<String> {
        Set(resolution.map { Array($0.savedToLive.keys) } ?? [])
    }

    var body: some View {
        Form {
            header
            Section("Preview") {
                LayoutPreviewView(preview: PreviewGeometry.model(for: profile, connectedIDs: connectedSavedIDs))
            }
            displaysSection
            AutoApplyRuleEditor(model: model, profile: profile)
            Section("Keyboard Shortcut") {
                ShortcutRecorder(model: model, profileID: profile.id)
            }
            advancedSection
        }
        .formStyle(.grouped)
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, new in
            if !nameFocused { name = new }
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                TextField("Layout name", text: $name, prompt: Text("Layout name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(.title2.weight(.semibold))
                    .help("Click to rename")
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .accessibilityLabel("Layout name")
                if model.currentProfileID == profile.id {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Active layout")
                }
                Spacer()
                actionsMenu
                Button(model.applyingProfileID == profile.id ? "Applying…" : "Apply Layout") {
                    coordinator.apply(profile.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(unavailableReason != nil || model.applyingProfileID != nil)
                .help(unavailableReason ?? "Apply this layout now")
            }
            if let nameProblem {
                Text(nameProblem).font(.caption).foregroundStyle(.red)
            }
            if let unavailableReason {
                Label(unavailableReason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if let last = model.lastResults[profile.id] {
                HStack {
                    Label(
                        "\(last.succeeded ? last.summary : "Failed: \(last.summary)") · \(last.date.formatted(date: .omitted, time: .shortened)) · \(last.origin.label)",
                        systemImage: last.succeeded ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(last.succeeded ? Color.secondary : Color.red)
                        .lineLimit(2)
                    if !last.succeeded {
                        Spacer()
                        Button("Details…") { coordinator.showFailureDetails(last) }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var unavailableReason: String? { model.unavailableReason(for: profile) }

    private var actionsMenu: some View {
        Menu {
            Button("Rename…") { coordinator.renameProfile(profile.id) }
            Button("Duplicate") { coordinator.duplicateProfile(profile.id) }
            Button("Export…") { coordinator.exportLayouts(profileIDs: [profile.id]) }
            Divider()
            Button("Delete…", role: .destructive) { coordinator.deleteProfile(profile.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
    }

    private func commitName() {
        guard name != profile.name else {
            nameProblem = nil
            return
        }
        do {
            try model.rename(profileID: profile.id, to: name)
            nameProblem = nil
            name = model.profile(id: profile.id)?.name ?? name
        } catch {
            nameProblem = WindowCoordinator.message(for: error)
            name = profile.name
        }
    }

    // MARK: Displays

    private var displaysSection: some View {
        Section("Displays") {
            ForEach(Array(profile.screens.enumerated()), id: \.offset) { _, screen in
                ScreenRow(model: model, profile: profile, screen: screen, resolution: resolution)
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section("Advanced") {
            DisclosureGroup("Raw Command", isExpanded: $showsRawCommand) {
                RawCommandBlock(model: model, profile: profile, resolution: resolution)
            }
            HStack {
                Button("Update From Current Layout…") { coordinator.updateFromCurrentLayout(profile.id) }
                    .disabled(!model.displayplacerStatus.isUsable)
                Spacer()
                Text("Saved \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RawCommandBlock: View {
    let model: AppModel
    let profile: LayoutProfile
    let resolution: DisplayResolution?

    var body: some View {
        Group {
            if let command = try? CommandBuilder.displayCommand(for: profile, resolution: resolution) {
                RawCommandView(
                    command: CommandBuilder.rawCommand(executablePath: model.displayplacerStatus.path, arguments: command.arguments),
                    note: command.usesConnectedDisplays ? "Uses the ids of the connected displays." : "Uses the saved display ids (not all displays are connected).")
            } else {
                Text("This layout contains settings that cannot be turned into a command.").foregroundStyle(.red)
            }
        }
    }
}

/// One saved screen (or mirror set): settings plus whether its displays are connected now.
private struct ScreenRow: View {
    let model: AppModel
    let profile: LayoutProfile
    let screen: ScreenSetting
    let resolution: DisplayResolution?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(screen.displayIDs.map { profile.displayInfo(for: $0).name }.joined(separator: " + "))
                    .fontWeight(.medium)
                if screen.isMirrorSet {
                    Text("Mirrored").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                connectionLabel
            }
            Text(settingsText).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var settingsText: String {
        guard screen.enabled else { return "Turned off" }
        var parts: [String] = []
        if let size = screen.resolution { parts.append("\(size.width) × \(size.height)") }
        if let hz = screen.refreshRate { parts.append("\(hz) Hz") }
        if let scaling = screen.scaling { parts.append(scaling ? "Scaled (HiDPI)" : "Not scaled") }
        if let depth = screen.colorDepth { parts.append("\(depth)-bit color") }
        if screen.effectiveRotation != 0 { parts.append("Rotated \(screen.effectiveRotation)°") }
        if let origin = screen.origin {
            parts.append(origin == .zero ? "Main display" : "Origin \(origin.x), \(origin.y)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var connectionLabel: some View {
        let connected = screen.displayIDs.map { resolution?.liveID(forSaved: $0) != nil }
        if resolution == nil {
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        } else if connected.allSatisfy({ $0 }) {
            Label(portText, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Not connected", systemImage: "bolt.horizontal.circle").font(.caption).foregroundStyle(.orange)
        }
    }

    private var portText: String {
        guard let snapshot = model.snapshot, let resolution else { return "Connected" }
        let labels = screen.displayIDs.compactMap { saved -> String? in
            guard let liveID = resolution.liveID(forSaved: saved), let live = snapshot.display(persistentID: liveID) else { return nil }
            return model.portLabel(for: live.connection)
        }
        return labels.isEmpty ? "Connected" : "Connected · \(labels.joined(separator: ", "))"
    }
}

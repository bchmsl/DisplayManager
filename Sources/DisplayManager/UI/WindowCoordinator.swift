import AppKit
import DisplayManagerCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case currentDisplays
    case profile(UUID)
}

/// Selection of the Layout Manager, so other parts of the app can select a profile.
@MainActor @Observable
final class ManagerState {
    var selection: SidebarItem? = .currentDisplays
}

/// Opens windows and runs the user-facing flows (save, rename, delete, import, export).
@MainActor
final class WindowCoordinator: MenuActions {
    private let model: AppModel
    let managerState = ManagerState()
    private var managerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsController: SettingsTabViewController?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Windows

    func showLayoutManager(selecting profileID: UUID?) {
        if let profileID { managerState.selection = .profile(profileID) }
        if managerWindow == nil {
            let root = LayoutManagerView(model: model, coordinator: self, state: managerState)
            let hosting = NSHostingController(rootView: root)
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Layout Manager"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 600))
            window.contentMinSize = NSSize(width: 720, height: 460)
            if !window.setFrameUsingName("LayoutManager") { window.center() }
            window.setFrameAutosaveName("LayoutManager")
            managerWindow = window
        }
        Task { await model.refreshSnapshot() }
        present(managerWindow)
    }

    func showSettings(tab: SettingsTab) {
        if settingsWindow == nil {
            let controller = SettingsTabViewController(model: model, coordinator: self)
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("Settings")
            settingsController = controller
            settingsWindow = window
        }
        settingsController?.select(tab)
        model.refreshLoginItemStatus()
        Task { await model.refreshDisplayplacer() }
        present(settingsWindow)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Menu actions

    func saveCurrentLayout() {
        Task { await runSaveFlow() }
    }

    private func runSaveFlow() async {
        let snapshot: SystemSnapshot
        do {
            snapshot = try await model.captureForSave()
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .malformedListOutput(detail: error.localizedDescription)
            Alerts.showError(managerError, title: "Couldn't read the current layout")
            return
        }
        guard let answer = SaveLayoutPrompt.run(snapshot: snapshot, model: model, suggestedName: model.suggestedProfileName()) else { return }
        var replacing: UUID?
        if let existing = model.profile(named: answer.name) {
            guard SaveLayoutPrompt.confirmReplace(name: existing.name) else { return }
            replacing = existing.id
        }
        guard let saved = model.saveProfile(name: answer.name, from: snapshot, replacing: replacing, createRule: answer.createRule) else {
            Alerts.showError("Couldn't save the layout", message: "The current display configuration is not available.")
            return
        }
        if answer.createRule, let rule = model.rule(for: saved.id), !model.conflictingRules(for: rule).isEmpty {
            Alerts.showInfo(
                "Another layout has the same Auto Apply conditions",
                message: "Only the first matching layout in the list is applied. Open the Layout Manager to change the rules.")
        }
        if managerWindow?.isVisible == true { managerState.selection = .profile(saved.id) }
    }

    func showFailureDetails(_ record: ApplyStatusRecord) {
        model.acknowledgeFailure()
        Alerts.showApplyFailure(record)
    }

    func toggleLaunchAtLogin() {
        model.refreshLoginItemStatus()
        let status = model.loginItemStatus
        if status == .requiresApproval {
            LoginItemController.openSystemSettingsLoginItems()
            return
        }
        do {
            try model.setLaunchAtLogin(!status.isOn)
            if model.loginItemStatus == .requiresApproval {
                Alerts.showInfo(
                    "Approve DisplayManager in Login Items",
                    message: "macOS needs your approval. Open System Settings › General › Login Items and allow DisplayManager.")
                LoginItemController.openSystemSettingsLoginItems()
            }
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .loginItemFailed(error.localizedDescription)
            Alerts.showError(managerError, title: "Couldn't change Launch at Login")
        }
    }

    // MARK: Profile flows

    func apply(_ profileID: UUID) {
        model.apply(profileID: profileID, origin: .manager)
    }

    func renameProfile(_ profileID: UUID) {
        guard let profile = model.profile(id: profileID) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Rename Layout"
        let field = NSTextField(string: profile.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel("Layout name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.rename(profileID: profileID, to: field.stringValue)
        } catch {
            Alerts.showError("Couldn't rename the layout", message: Self.message(for: error))
        }
    }

    static func message(for problem: AppModel.RenameProblem) -> String {
        switch problem {
        case .empty: "The name cannot be empty."
        case .tooLong: "The name can have at most \(ImportValidator.maximumNameLength) characters."
        case .taken: "Another layout already uses this name."
        }
    }

    func duplicateProfile(_ profileID: UUID) {
        if let copy = model.duplicate(profileID: profileID) {
            managerState.selection = .profile(copy.id)
        }
    }

    func deleteProfile(_ profileID: UUID) {
        guard let profile = model.profile(id: profileID) else { return }
        var message = "This removes the layout"
        if model.rule(for: profileID) != nil { message += ", its Auto Apply rule" }
        if profile.shortcut != nil { message += " and its keyboard shortcut" }
        message += ". This cannot be undone."
        guard Alerts.confirm("Delete “\(profile.name)”?", message: message, confirmTitle: "Delete", destructive: true) else { return }
        if managerState.selection == .profile(profileID) { managerState.selection = .currentDisplays }
        model.delete(profileID: profileID)
    }

    func updateFromCurrentLayout(_ profileID: UUID) {
        guard let profile = model.profile(id: profileID) else { return }
        guard Alerts.confirm(
            "Update “\(profile.name)” from the current layout?",
            message: "The saved display settings are replaced with the current arrangement. The name, keyboard shortcut and Auto Apply rule are kept.",
            confirmTitle: "Update")
        else { return }
        Task {
            do {
                try await model.updateFromCurrentLayout(profileID: profileID)
            } catch {
                let managerError = (error as? DisplayManagerError) ?? .malformedListOutput(detail: error.localizedDescription)
                Alerts.showError(managerError, title: "Couldn't read the current layout")
            }
        }
    }

    // MARK: Import and export

    func exportLayouts(profileIDs: Set<UUID>? = nil) {
        let document = model.exportDocument(profileIDs: profileIDs)
        guard !document.profiles.isEmpty else {
            Alerts.showInfo("Nothing to export", message: "Save a layout first.")
            return
        }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if let profileIDs, profileIDs.count == 1, let profile = document.profiles.first {
            panel.nameFieldStringValue = "\(Self.safeFileName(profile.name)).json"
        } else {
            panel.nameFieldStringValue = "Display Layouts.json"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.export(profileIDs: profileIDs, to: url)
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .persistenceFailed(error.localizedDescription)
            Alerts.showError("Couldn't export layouts", message: managerError.userMessage, details: managerError.diagnosticDetail)
        }
    }

    func importLayouts() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let imported: LayoutDocument
        do {
            imported = try model.store.readImport(from: url)
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .invalidDocument(error.localizedDescription)
            Alerts.showError("Couldn't import “\(url.lastPathComponent)”", message: managerError.userMessage + " Nothing was changed.",
                             details: managerError.diagnosticDetail)
            return
        }
        guard !imported.profiles.isEmpty else {
            Alerts.showInfo("Nothing to import", message: "“\(url.lastPathComponent)” contains no layouts.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Import \(counted(imported.profiles.count, "layout")) and \(counted(imported.rules.count, "rule"))?"
        alert.informativeText = "Add keeps your current layouts. Replace All removes them (a backup is saved first)."
        alert.addButton(withTitle: "Add")
        let replace = alert.addButton(withTitle: "Replace All")
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let mode: ImportMode
        switch alert.runModal() {
        case .alertFirstButtonReturn: mode = .add
        case .alertSecondButtonReturn:
            guard model.profiles.isEmpty || Alerts.confirm(
                "Replace all \(model.profiles.count) layouts?",
                message: "Your current layouts, rules and learned ports are replaced by the imported file. A backup is saved in the data folder first.",
                confirmTitle: "Replace All", destructive: true)
            else { return }
            mode = .replaceAll
        default: return
        }

        do {
            let summary = try model.applyImport(imported, mode: mode)
            var notes: [String] = []
            if summary.renamedProfiles > 0 {
                notes.append("\(counted(summary.renamedProfiles, "layout")) renamed because the name was already used.")
            }
            if summary.disabledRules > 0 {
                notes.append("\(counted(summary.disabledRules, "rule")) turned off because another rule has the same conditions.")
            }
            if summary.removedShortcuts > 0 {
                notes.append("\(counted(summary.removedShortcuts, "keyboard shortcut")) removed because they were already used.")
            }
            Alerts.showInfo("Imported \(counted(summary.addedProfiles, "layout"))", message: notes.isEmpty ? "Done." : notes.joined(separator: "\n"))
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .persistenceFailed(error.localizedDescription)
            Alerts.showError("Import failed", message: managerError.userMessage + " Nothing was changed.", details: managerError.diagnosticDetail)
        }
    }

    func showDataFolder() {
        try? FileManager.default.createDirectory(at: model.store.directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: model.store.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL])
        } else {
            NSWorkspace.shared.open(model.store.directory)
        }
    }

    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Layout" : cleaned
    }
}

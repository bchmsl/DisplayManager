import AppKit
import DisplayManagerCore

/// Actions the status menu triggers. Implemented by the window coordinator.
@MainActor
protocol MenuActions: AnyObject {
    func saveCurrentLayout()
    func showLayoutManager(selecting profileID: UUID?)
    func showSettings(tab: SettingsTab)
    func showFailureDetails(_ record: ApplyStatusRecord)
    func toggleLaunchAtLogin()
}

/// A menu item that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}

/// Builds the status menu from cached state (no subprocess runs when the menu opens).
@MainActor
enum StatusMenuBuilder {
    static func build(_ menu: NSMenu, model: AppModel, actions: MenuActions) {
        menu.removeAllItems()

        // Status
        let state = model.currentLayoutState
        if state == .displayplacerMissing {
            let item = ActionMenuItem(title: "displayplacer not found") { actions.showSettings(tab: .displayplacer) }
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            item.toolTip = "Open Settings to see how to install displayplacer."
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: state.menuTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let failure = model.pendingFailure {
            let item = ActionMenuItem(title: "Couldn't apply \(failure.profileName) – Details…") { actions.showFailureDetails(failure) }
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            item.toolTip = failure.failure?.message
            menu.addItem(item)
        }
        if model.automationPaused {
            let item = ActionMenuItem(title: "Automation paused after repeated applies – Resume") {
                model.automation?.resume()
            }
            item.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Layouts
        menu.addItem(NSMenuItem.sectionHeader(title: "Layouts"))
        if model.profiles.isEmpty {
            let item = NSMenuItem(title: "No saved layouts", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for profile in model.profiles {
            let item = ActionMenuItem(title: profile.name) { model.apply(profileID: profile.id, origin: .menu) }
            item.state = profile.id == model.currentProfileID ? .on : .off
            if let shortcut = profile.shortcut, let equivalent = KeyEquivalent(shortcut) {
                item.keyEquivalent = equivalent.key
                item.keyEquivalentModifierMask = equivalent.modifiers
            }
            if let reason = model.unavailableReason(for: profile) {
                item.isEnabled = false
                item.toolTip = reason
            } else if let failure = model.lastResults[profile.id]?.failure {
                item.toolTip = "Last apply failed: \(failure.message)"
            }
            item.setAccessibilityLabel(profile.id == model.currentProfileID ? "\(profile.name), current layout" : profile.name)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Layout actions
        let save = ActionMenuItem(title: "Save Current Layout…") { actions.saveCurrentLayout() }
        save.isEnabled = model.displayplacerStatus.isUsable
        if !save.isEnabled { save.toolTip = model.displayplacerStatus.summary }
        menu.addItem(save)
        menu.addItem(ActionMenuItem(title: "Layout Manager…") { actions.showLayoutManager(selecting: nil) })
        menu.addItem(.separator())

        // Toggles
        let autoApply = ActionMenuItem(title: "Auto Apply") { model.setAutoApplyEnabled(!model.autoApplyEnabled) }
        autoApply.state = model.autoApplyEnabled ? .on : .off
        autoApply.toolTip = "Apply a layout automatically when its displays are connected (and at app launch)."
        menu.addItem(autoApply)

        let wake = ActionMenuItem(title: "Reapply After Wake") { model.setReapplyAfterWake(!model.reapplyAfterWake) }
        wake.state = model.reapplyAfterWake ? .on : .off
        wake.toolTip = "Apply the matching layout again after the Mac wakes from sleep."
        menu.addItem(wake)

        let loginStatus = model.loginItemStatus
        let login = ActionMenuItem(title: loginStatus == .requiresApproval ? "Launch at Login (Needs Approval)" : "Launch at Login") {
            actions.toggleLaunchAtLogin()
        }
        login.state = loginStatus.isOn ? .on : .off
        if loginStatus == .requiresApproval {
            login.toolTip = "Allow DisplayManager in System Settings › General › Login Items."
        }
        menu.addItem(login)
        menu.addItem(.separator())

        // App
        menu.addItem(ActionMenuItem(title: "Displays Settings…") { SystemSettingsOpener.openDisplays() })
        menu.addItem(ActionMenuItem(title: "Settings…", keyEquivalent: ",") { actions.showSettings(tab: .general) })
        menu.addItem(ActionMenuItem(title: "Quit DisplayManager", keyEquivalent: "q") { NSApp.terminate(nil) })
    }
}

/// Menu key equivalent for a stored shortcut (display only; the Carbon hotkey does the work).
struct KeyEquivalent {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ shortcut: KeyShortcut) {
        guard let key = KeyNames.menuKeyEquivalent(forKeyCode: shortcut.keyCode, displayString: shortcut.displayString) else { return nil }
        self.key = key
        var flags: NSEvent.ModifierFlags = []
        for modifier in shortcut.modifiers {
            switch modifier {
            case .command: flags.insert(.command)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .control: flags.insert(.control)
            }
        }
        modifiers = flags
    }
}

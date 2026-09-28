import AppKit
import DisplayManagerCore
import Observation

/// The menu bar item. Left click opens the menu; right click and control-click open System Settings › Displays.
///
/// The menu is attached only for the duration of a left-click tracking session, so a right click
/// never shows it and native highlighting and positioning are kept.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let iconName = "display"
    static let warningIconName = "display.trianglebadge.exclamationmark"

    private let model: AppModel
    private let actions: MenuActions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(model: AppModel, actions: MenuActions) {
        self.model = model
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("DisplayManager")
            button.toolTip = "DisplayManager: click for layouts, right-click for Displays settings"
        }
        updateIcon()
        observeIcon()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.logVisibility()
        }
    }

    /// Logged once after launch. A hidden item usually means the menu bar is full (notch) or the item is turned off
    /// in System Settings › Menu Bar.
    private func logVisibility() {
        let window = statusItem.button?.window
        if statusItem.isVisible, let window, window.isVisible, window.occlusionState.contains(.visible) {
            Log.info(.app, "Menu bar item is visible")
        } else {
            Log.warning(.app, "Menu bar item is not visible. The menu bar may be full, or DisplayManager is off in System Settings › Menu Bar › Allow in the Menu Bar.")
        }
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            SystemSettingsOpener.openDisplays()
            return
        }
        statusItem.menu = menu
        sender.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: Icon

    private func observeIcon() {
        withObservationTracking {
            _ = model.showsFailureBadge
            _ = model.automationPaused
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeIcon()
            }
        }
    }

    private func updateIcon() {
        let warning = model.showsFailureBadge
        let name = warning ? Self.warningIconName : Self.iconName
        let description = warning ? "DisplayManager: a layout could not be applied" : "DisplayManager"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: Self.iconName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshLoginItemStatus()
        StatusMenuBuilder.build(menu, model: model, actions: actions)
    }
}

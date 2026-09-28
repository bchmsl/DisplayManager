import AppKit
import DisplayManagerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var coordinator: WindowCoordinator?
    private var statusItem: StatusItemController?
    private var eventMonitor: DisplayEventMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info(.app, "DisplayManager \(AppInfo.version) (\(AppInfo.build)) started")
        let model = AppModel()
        let coordinator = WindowCoordinator(model: model)
        self.model = model
        self.coordinator = coordinator

        model.onManualApplyFailure = { record in
            // Let the menu finish closing before a modal alert appears.
            DispatchQueue.main.async { Alerts.showApplyFailure(record) }
        }
        model.onPersistenceError = { error in
            DispatchQueue.main.async {
                Alerts.showError(error, title: "Couldn't save layouts")
            }
        }

        MainMenu.install(actions: coordinator)
        statusItem = StatusItemController(model: model, actions: coordinator)

        let monitor = DisplayEventMonitor { [weak model] event in
            model?.automation?.handle(event)
        }
        monitor.start()
        eventMonitor = monitor

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshLoginItemStatus() }
        }

        let loadResult = model.startupLoadResult
        Task {
            await model.start()
            handleStartup(loadResult: loadResult, model: model, coordinator: coordinator)
        }
    }

    private func handleStartup(loadResult: ProfileStore.LoadResult, model: AppModel, coordinator: WindowCoordinator) {
        switch loadResult {
        case .recovered(let error, let movedTo):
            var message = "The saved layouts could not be read, so DisplayManager started with no layouts."
            if let movedTo {
                message += " The unreadable file was kept as “\(movedTo.lastPathComponent)” in the data folder."
            }
            Alerts.showError("Saved layouts could not be read", message: message, details: error.diagnosticDetail ?? error.userMessage)
        case .missing:
            if !model.preferences.hasCompletedFirstLaunch {
                model.preferences.hasCompletedFirstLaunch = true
                coordinator.showLayoutManager(selecting: nil)
            }
        case .loaded:
            break
        }
        if !model.preferences.hasCompletedFirstLaunch { model.preferences.hasCompletedFirstLaunch = true }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder or Spotlight shows the Layout Manager.
        if !flag { coordinator?.showLayoutManager(selecting: nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventMonitor?.stop()
        Log.info(.app, "DisplayManager quit")
    }
}

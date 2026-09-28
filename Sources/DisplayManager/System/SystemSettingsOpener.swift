import AppKit

/// Opens System Settings › Displays with a fallback chain.
///
/// `NSWorkspace.open` can return true without reaching the right pane; that cannot be detected.
@MainActor
enum SystemSettingsOpener {
    static let displaysExtensionURL = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
    static let legacyDisplaysURL = "x-apple.systempreferences:com.apple.preference.displays"
    static let legacyPanePath = "/System/Library/PreferencePanes/Displays.prefPane"
    static let systemSettingsBundleID = "com.apple.systempreferences"

    static func openDisplays() {
        for (step, string) in [displaysExtensionURL, legacyDisplaysURL].enumerated() {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                Log.info(.app, "Opened Displays settings (step \(step + 1))")
                return
            }
            Log.warning(.app, "Opening Displays settings failed at step \(step + 1)")
        }
        if FileManager.default.fileExists(atPath: legacyPanePath),
           NSWorkspace.shared.open(URL(fileURLWithPath: legacyPanePath)) {
            Log.info(.app, "Opened Displays settings (step 3)")
            return
        }
        Log.warning(.app, "Opening Displays settings failed at step 3")
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemSettingsBundleID) else {
            Log.error(.app, "System Settings was not found")
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Log.error(.app, "Opening System Settings failed", details: error.localizedDescription)
            } else {
                Log.info(.app, "Opened System Settings (step 4)")
            }
        }
    }
}

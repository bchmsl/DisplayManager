import DisplayManagerCore
import Foundation
import ServiceManagement

/// Launch at Login through `SMAppService.mainApp`. The state is never stored; it is always read from macOS.
@MainActor
enum LoginItemController {
    enum Status: Equatable {
        case enabled
        case requiresApproval
        case disabled
        /// macOS cannot find the app for registration (for example when it runs from a build folder).
        case notFound

        /// The toggle is on for enabled and for "needs approval" (the user asked for it; macOS is waiting).
        var isOn: Bool { self == .enabled || self == .requiresApproval }
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .disabled
        @unknown default: .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.notice(.login, enabled ? "Launch at Login registered" : "Launch at Login unregistered")
        } catch {
            Log.error(.login, "Launch at Login change failed", details: error.localizedDescription)
            throw DisplayManagerError.loginItemFailed(error.localizedDescription)
        }
    }

    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

import Foundation

/// App preferences in `UserDefaults`. Launch at Login is not stored here; it is always read from the system.
@MainActor
final class Preferences {
    enum Key {
        static let autoApplyEnabled = "autoApplyEnabled"
        static let reapplyAfterWake = "reapplyAfterWake"
        static let settleDelaySeconds = "settleDelaySeconds"
        static let displayplacerPathOverride = "displayplacerPathOverride"
        static let hasCompletedFirstLaunch = "hasCompletedFirstLaunch"
    }

    static let settleDelayRange: ClosedRange<Double> = 0...10

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoApplyEnabled: true,
            Key.reapplyAfterWake: true,
            Key.settleDelaySeconds: 2.0,
            Key.hasCompletedFirstLaunch: false,
        ])
    }

    var autoApplyEnabled: Bool {
        get { defaults.bool(forKey: Key.autoApplyEnabled) }
        set { defaults.set(newValue, forKey: Key.autoApplyEnabled) }
    }

    var reapplyAfterWake: Bool {
        get { defaults.bool(forKey: Key.reapplyAfterWake) }
        set { defaults.set(newValue, forKey: Key.reapplyAfterWake) }
    }

    var settleDelaySeconds: Double {
        get { min(max(defaults.double(forKey: Key.settleDelaySeconds), Self.settleDelayRange.lowerBound), Self.settleDelayRange.upperBound) }
        set { defaults.set(min(max(newValue, Self.settleDelayRange.lowerBound), Self.settleDelayRange.upperBound), forKey: Key.settleDelaySeconds) }
    }

    var displayplacerPathOverride: String? {
        get {
            let value = defaults.string(forKey: Key.displayplacerPathOverride)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.displayplacerPathOverride)
            } else {
                defaults.removeObject(forKey: Key.displayplacerPathOverride)
            }
        }
    }

    var hasCompletedFirstLaunch: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstLaunch) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstLaunch) }
    }
}

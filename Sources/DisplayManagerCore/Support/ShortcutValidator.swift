import Foundation

public enum ShortcutProblem: Hashable, Sendable, CustomStringConvertible {
    case missingModifier
    case duplicate(profileName: String)
    case usedBySystem
    case usedByAnotherApp
    case registrationFailed(status: Int32)

    public var description: String {
        switch self {
        case .missingModifier: "Use at least one of ⌘, ⌥ or ⌃."
        case .duplicate(let name): "Already used by “\(name)”."
        case .usedBySystem: "Used by a macOS shortcut."
        case .usedByAnotherApp: "Used by another app."
        case .registrationFailed(let status): "macOS refused this shortcut (error \(status))."
        }
    }
}

/// Checks that do not need the system. Conflict checks against macOS and other apps happen in the app.
public enum ShortcutValidator {
    public static func validate(_ shortcut: KeyShortcut, for profileID: UUID, profiles: [LayoutProfile]) -> ShortcutProblem? {
        let modifiers = Set(shortcut.modifiers)
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return .missingModifier }
        if let other = profiles.first(where: { $0.id != profileID && $0.shortcut?.sameCombination(as: shortcut) == true }) {
            return .duplicate(profileName: other.name)
        }
        return nil
    }
}

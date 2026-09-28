import Foundation

/// A displayplacer command for a profile, ready to show or run.
public struct ResolvedCommand: Hashable, Sendable {
    /// One element per screen spec, passed to `Process.arguments` as is.
    public var arguments: [String]
    /// True when every id was mapped to a connected display.
    public var usesConnectedDisplays: Bool

    public init(arguments: [String], usesConnectedDisplays: Bool) {
        self.arguments = arguments
        self.usesConnectedDisplays = usesConnectedDisplays
    }
}

public enum CommandBuilder {
    public static let displayplacerName = "displayplacer"

    /// Encodes screens into displayplacer arguments, replacing saved ids with live ids from `idMap`.
    public static func arguments(for screens: [ScreenSetting], idMap: [String: String] = [:]) throws -> [String] {
        try screens.map { screen in
            var mapped = screen
            mapped.displayIDs = screen.displayIDs.map { idMap[$0] ?? $0 }
            return try ScreenSpecCodec.encode(mapped)
        }
    }

    /// Arguments that apply `profile` to the connected displays.
    ///
    /// Every enabled display must be resolved (callers check this first and report which display is
    /// missing). Disabled displays that are not connected are left out, because displayplacer fails on
    /// unknown ids and there is nothing to turn off.
    public static func applyArguments(for profile: LayoutProfile, resolution: DisplayResolution) throws -> [String] {
        var screens: [ScreenSetting] = []
        for screen in profile.screens {
            let resolved = screen.displayIDs.compactMap { resolution.liveID(forSaved: $0) }
            if screen.enabled {
                guard resolved.count == screen.displayIDs.count else {
                    throw DisplayManagerError.invalidScreenSpec("id:\(screen.displayIDs.joined(separator: "+"))")
                }
            } else if resolved.isEmpty {
                continue
            }
            var mapped = screen
            mapped.displayIDs = resolved
            screens.append(mapped)
        }
        return try arguments(for: screens)
    }

    /// The command to show and copy. Uses connected display ids when every display is connected,
    /// otherwise the saved ids.
    public static func displayCommand(for profile: LayoutProfile, resolution: DisplayResolution?) throws -> ResolvedCommand {
        if let resolution, resolution.unresolvedSavedIDs.isEmpty {
            return ResolvedCommand(arguments: try arguments(for: profile.screens, idMap: resolution.savedToLive), usesConnectedDisplays: true)
        }
        return ResolvedCommand(arguments: try arguments(for: profile.screens), usesConnectedDisplays: false)
    }

    /// Shell form for display and copy: `'<path>' "<spec>" "<spec>"`.
    /// Specs are safe inside double quotes because every token passed the codec whitelist.
    public static func rawCommand(executablePath: String?, arguments: [String]) -> String {
        let program = executablePath.map(shellQuoted) ?? displayplacerName
        return ([program] + arguments.map { "\"\($0)\"" }).joined(separator: " ")
    }

    /// Quotes a path for a POSIX shell only when needed.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

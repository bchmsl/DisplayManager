import Foundation

public struct ImportIssue: Hashable, Sendable, CustomStringConvertible {
    public var context: String?
    public var message: String

    public init(context: String?, message: String) {
        self.context = context
        self.message = message
    }

    public var description: String { context.map { "\($0): \(message)" } ?? message }
}

public enum ImportMode: Sendable {
    /// Keep existing data and add the imported layouts.
    case add
    /// Replace all layouts, rules and learned ports (the caller makes a backup first).
    case replaceAll
}

public struct ImportSummary: Hashable, Sendable {
    public var addedProfiles = 0
    public var addedRules = 0
    public var addedPorts = 0
    public var renamedProfiles = 0
    public var disabledRules = 0
    public var removedShortcuts = 0

    public init() {}
}

/// Validates a whole document before anything changes, then merges it.
public enum ImportValidator {
    public static let maximumNameLength = 100
    public static let dimensionRange = 1...32768
    public static let refreshRateRange = 1...1000
    public static let colorDepthRange = 1...32
    public static let validRotations: Set<Int> = [0, 90, 180, 270]
    public static let originLimit = 100_000

    public static func validate(_ document: LayoutDocument) -> [ImportIssue] {
        var issues: [ImportIssue] = []
        var profileIDs = Set<UUID>()
        for (index, profile) in document.profiles.enumerated() {
            let context = profile.name.isEmpty ? "Layout \(index + 1)" : "“\(profile.name)”"
            func problem(_ message: String) { issues.append(ImportIssue(context: context, message: message)) }

            if !profileIDs.insert(profile.id).inserted { problem("duplicate layout id") }
            let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty || profile.name.count > maximumNameLength {
                problem("name must be 1–\(maximumNameLength) characters")
            }
            if profile.screens.isEmpty { problem("no screens") }

            var seenIDs = Set<String>()
            for screen in profile.screens {
                if screen.displayIDs.isEmpty { problem("a screen has no display id") }
                for id in screen.displayIDs where !seenIDs.insert(id.lowercased()).inserted {
                    problem("display id \(id) is used more than once")
                }
                do {
                    _ = try ScreenSpecCodec.encode(screen)
                    for (key, value) in screen.extraArguments {
                        try ScreenSpecCodec.validateExtraArgument(key: key, value: value)
                    }
                } catch let error as DisplayManagerError {
                    problem(error.userMessage)
                } catch {
                    problem("invalid screen settings")
                }
                issues += screenRangeIssues(screen).map { ImportIssue(context: context, message: $0) }
            }

            let enabled = profile.screens.filter(\.enabled)
            if !profile.screens.isEmpty {
                if enabled.isEmpty {
                    problem("at least one display must be on")
                } else if !(enabled.count == 1 && enabled[0].origin == nil) {
                    if enabled.contains(where: { $0.origin == nil }) { problem("a display that is on has no position") }
                    let mainCount = enabled.filter { $0.origin == .zero }.count
                    if mainCount != 1 { problem("exactly one display that is on must be at position (0,0)") }
                }
            }

            var metadataIDs = Set<String>()
            for display in profile.displays {
                if !metadataIDs.insert(display.persistentID.lowercased()).inserted {
                    problem("display metadata for \(display.persistentID) appears more than once")
                }
                if (try? ScreenSpecCodec.validateID(display.persistentID)) == nil { problem("invalid display id") }
                if display.name.count > 200 { problem("display name is too long") }
                if let connection = display.connection, let message = fingerprintIssue(connection) { problem(message) }
            }
            if let shortcut = profile.shortcut, let message = shortcutIssue(shortcut) { problem(message) }
        }

        var ruleIDs = Set<UUID>()
        for (index, rule) in document.rules.enumerated() {
            let context = "Rule \(index + 1)"
            if !ruleIDs.insert(rule.id).inserted { issues.append(ImportIssue(context: context, message: "duplicate rule id")) }
            guard let profile = document.profiles.first(where: { $0.id == rule.profileID }) else {
                issues.append(ImportIssue(context: context, message: "refers to a layout that is not in the file"))
                continue
            }
            let profileIDSet = Set(profile.allDisplayIDs.map { $0.lowercased() })
            for requirement in rule.connectionRequirements {
                if !profileIDSet.contains(requirement.persistentID.lowercased()) {
                    issues.append(ImportIssue(context: context, message: "port requirement refers to a display that is not in “\(profile.name)”"))
                }
                if let message = fingerprintIssue(requirement.connection) {
                    issues.append(ImportIssue(context: context, message: message))
                }
            }
        }

        var portKeys = Set<String>()
        for port in document.knownPorts {
            if let message = fingerprintIssue(port.connection) {
                issues.append(ImportIssue(context: "Learned port", message: message))
            }
            if !portKeys.insert(port.connection.key).inserted {
                issues.append(ImportIssue(context: "Learned port", message: "\(port.connection.technicalLabel) appears more than once"))
            }
            if port.name.count > maximumNameLength {
                issues.append(ImportIssue(context: "Learned port", message: "name must be at most \(maximumNameLength) characters"))
            }
        }
        return issues
    }

    static func screenRangeIssues(_ screen: ScreenSetting) -> [String] {
        var issues: [String] = []
        if let size = screen.resolution, !dimensionRange.contains(size.width) || !dimensionRange.contains(size.height) {
            issues.append("resolution \(size) is out of range")
        }
        if let hz = screen.refreshRate, !refreshRateRange.contains(hz) { issues.append("refresh rate \(hz) is out of range") }
        if let depth = screen.colorDepth, !colorDepthRange.contains(depth) { issues.append("color depth \(depth) is out of range") }
        if let rotation = screen.rotation, !validRotations.contains(rotation) { issues.append("rotation \(rotation) is not 0, 90, 180 or 270") }
        if let origin = screen.origin, abs(origin.x) > originLimit || abs(origin.y) > originLimit {
            issues.append("position \(origin) is out of range")
        }
        return issues
    }

    static func fingerprintIssue(_ connection: ConnectionFingerprint) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,._-")
        guard !connection.hostModel.isEmpty, connection.hostModel.count <= 64,
              connection.hostModel.unicodeScalars.allSatisfy(allowed.contains)
        else { return "invalid Mac model in a port" }
        guard (0...64).contains(connection.portNumber) else { return "invalid port number \(connection.portNumber)" }
        return nil
    }

    static func shortcutIssue(_ shortcut: KeyShortcut) -> String? {
        guard (0...0xFFFF).contains(shortcut.keyCode) else { return "invalid shortcut key" }
        guard shortcut.displayString.count <= 32 else { return "invalid shortcut label" }
        return nil
    }

    // MARK: Merge

    /// Merges an already validated document. `add` never changes existing data.
    public static func merge(_ imported: LayoutDocument, into existing: LayoutDocument, mode: ImportMode) -> (LayoutDocument, ImportSummary) {
        var summary = ImportSummary()
        switch mode {
        case .replaceAll:
            var result = imported
            result.version = LayoutDocument.currentVersion
            summary.addedProfiles = imported.profiles.count
            summary.addedRules = imported.rules.count
            summary.addedPorts = imported.knownPorts.count
            return (result, summary)
        case .add:
            break
        }

        var result = existing
        var usedProfileIDs = Set(existing.profiles.map(\.id))
        var usedRuleIDs = Set(existing.rules.map(\.id))
        var usedNames = Set(existing.profiles.map { $0.name.lowercased() })
        var profileIDMap: [UUID: UUID] = [:]

        for var profile in imported.profiles {
            let originalID = profile.id
            if usedProfileIDs.contains(profile.id) { profile.id = UUID() }
            usedProfileIDs.insert(profile.id)
            profileIDMap[originalID] = profile.id

            let uniqueName = uniqueName(for: profile.name, used: usedNames)
            if uniqueName != profile.name { summary.renamedProfiles += 1 }
            profile.name = uniqueName
            usedNames.insert(uniqueName.lowercased())

            if let shortcut = profile.shortcut,
               result.profiles.contains(where: { $0.shortcut?.sameCombination(as: shortcut) == true }) {
                profile.shortcut = nil
                summary.removedShortcuts += 1
            }
            result.profiles.append(profile)
            summary.addedProfiles += 1
        }

        for var rule in imported.rules {
            guard let profileID = profileIDMap[rule.profileID] else { continue }
            rule.profileID = profileID
            if usedRuleIDs.contains(rule.id) { rule.id = UUID() }
            usedRuleIDs.insert(rule.id)
            if rule.isEnabled, !RuleMatcher.conflictingRules(for: rule, rules: result.rules, profiles: result.profiles).isEmpty {
                rule.isEnabled = false
                summary.disabledRules += 1
            }
            result.rules.append(rule)
            summary.addedRules += 1
        }

        let existingPortKeys = Set(existing.knownPorts.map(\.connection.key))
        for port in imported.knownPorts where !existingPortKeys.contains(port.connection.key) {
            result.knownPorts.append(port)
            summary.addedPorts += 1
        }
        return (result, summary)
    }

    /// "Desk", then "Desk 2", "Desk 3", … (case-insensitive).
    public static func uniqueName(for name: String, used: Set<String>) -> String {
        guard used.contains(name.lowercased()) else { return name }
        var counter = 2
        while used.contains("\(name) \(counter)".lowercased()) { counter += 1 }
        return "\(name) \(counter)"
    }
}

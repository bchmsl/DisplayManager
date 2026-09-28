import Foundation

/// Why a rule does not match the connected displays right now.
public enum RuleMismatch: Hashable, Sendable, CustomStringConvertible {
    case displayNotConnected(name: String)
    case extraDisplayConnected(name: String)
    case portDiffers(name: String, expected: ConnectionFingerprint, actual: ConnectionState)

    public var description: String {
        switch self {
        case .displayNotConnected(let name): "\(name) is not connected"
        case .extraDisplayConnected(let name): "\(name) is connected but not part of this layout"
        case .portDiffers(let name, let expected, let actual):
            switch actual {
            case .external(let fingerprint) where fingerprint.hostModel != expected.hostModel:
                "\(name): the port was learned on a different Mac model (\(expected.hostModel))"
            case .external(let fingerprint):
                "\(name) is connected to \(fingerprint.technicalLabel), not \(expected.technicalLabel)"
            case .unidentified(let reason):
                "\(name): \(reason.userMessage)"
            case .builtIn:
                "\(name) is the built-in display"
            }
        }
    }
}

public struct RuleEvaluation: Hashable, Sendable {
    public var rule: AutoApplyRule
    public var profile: LayoutProfile
    public var mismatches: [RuleMismatch]

    public var isSatisfied: Bool { mismatches.isEmpty }
}

/// Deterministic rule matching: exact display set plus optional per-display port requirements.
public enum RuleMatcher {
    /// Checks one rule against the snapshot, ignoring triggers and the enabled flag.
    public static func evaluate(rule: AutoApplyRule, profile: LayoutProfile, snapshot: SystemSnapshot) -> RuleEvaluation {
        let resolution = DisplayResolver.resolve(profile: profile, snapshot: snapshot)
        var mismatches = displaySetMismatches(profile: profile, resolution: resolution, snapshot: snapshot)

        for requirement in rule.connectionRequirements {
            let name = profile.displayInfo(for: requirement.persistentID).name
            guard let liveID = resolution.liveID(forSaved: requirement.persistentID),
                  let live = snapshot.display(persistentID: liveID)
            else {
                if !mismatches.contains(.displayNotConnected(name: name)) {
                    mismatches.append(.displayNotConnected(name: name))
                }
                continue
            }
            // An unidentified port never satisfies a requirement.
            if live.connection.fingerprint != requirement.connection {
                mismatches.append(.portDiffers(name: name, expected: requirement.connection, actual: live.connection))
            }
        }
        return RuleEvaluation(rule: rule, profile: profile, mismatches: mismatches)
    }

    /// The connected displays must be exactly the profile's displays. Displays the profile turns off may be absent.
    public static func displaySetMismatches(profile: LayoutProfile, resolution: DisplayResolution, snapshot: SystemSnapshot) -> [RuleMismatch] {
        var mismatches: [RuleMismatch] = []
        var seen = Set<String>()
        for id in profile.enabledDisplayIDs where seen.insert(id).inserted {
            if resolution.liveID(forSaved: id) == nil {
                mismatches.append(.displayNotConnected(name: profile.displayInfo(for: id).name))
            }
        }
        let resolvedLive = Set(resolution.resolvedLiveIDs.map { $0.lowercased() })
        for live in snapshot.displays where !resolvedLive.contains(live.persistentID.lowercased()) {
            mismatches.append(.extraDisplayConnected(name: live.name))
        }
        return mismatches
    }

    /// The best satisfied rule for a trigger: most connection requirements wins; ties go to the earliest
    /// profile in user order, then the earliest rule.
    public static func bestMatch(
        trigger: AutomationTrigger,
        rules: [AutoApplyRule],
        profiles: [LayoutProfile],
        snapshot: SystemSnapshot
    ) -> RuleEvaluation? {
        let profileIndex = Dictionary(profiles.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = rules.enumerated().compactMap { ruleIndex, rule -> (RuleEvaluation, Int, Int)? in
            guard rule.isEnabled, rule.triggers.contains(trigger),
                  let index = profileIndex[rule.profileID]
            else { return nil }
            let evaluation = evaluate(rule: rule, profile: profiles[index], snapshot: snapshot)
            return evaluation.isSatisfied ? (evaluation, index, ruleIndex) : nil
        }
        return candidates.min { lhs, rhs in
            let lhsCount = lhs.0.rule.connectionRequirements.count
            let rhsCount = rhs.0.rule.connectionRequirements.count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }?.0
    }

    /// A key that is equal for rules with identical conditions.
    public static func conditionKey(rule: AutoApplyRule, profile: LayoutProfile) -> String {
        let displays = Set(profile.allDisplayIDs.map { $0.lowercased() }).sorted().joined(separator: ",")
        let requirements = rule.connectionRequirements
            .map { "\($0.persistentID.lowercased())=\($0.connection.key)" }
            .sorted()
            .joined(separator: ",")
        return displays + "|" + requirements
    }

    /// Other enabled rules with the same conditions and at least one shared trigger.
    public static func conflictingRules(for rule: AutoApplyRule, rules: [AutoApplyRule], profiles: [LayoutProfile]) -> [AutoApplyRule] {
        guard let profile = profiles.first(where: { $0.id == rule.profileID }) else { return [] }
        let key = conditionKey(rule: rule, profile: profile)
        return rules.filter { other in
            guard other.id != rule.id, other.isEnabled,
                  let otherProfile = profiles.first(where: { $0.id == other.profileID }),
                  AutomationTrigger.allCases.contains(where: { rule.triggers.contains($0) && other.triggers.contains($0) })
            else { return false }
            return conditionKey(rule: other, profile: otherProfile) == key
        }
    }
}

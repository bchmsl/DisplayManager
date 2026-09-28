import Foundation

/// Why automation is evaluating the displays.
public enum AutomationReason: String, Hashable, Sendable {
    case launch
    case displayChange
    case wake
    /// The user session became active again (fast user switching, login window). Handled like wake.
    case sessionActive

    public var trigger: AutomationTrigger {
        switch self {
        case .launch: .launch
        case .displayChange: .displayConnect
        case .wake, .sessionActive: .wake
        }
    }
}

public struct AutomationSettings: Hashable, Sendable {
    /// Gates the launch and display-connection triggers.
    public var autoApplyEnabled: Bool
    /// Gates the wake trigger.
    public var reapplyAfterWake: Bool

    public init(autoApplyEnabled: Bool, reapplyAfterWake: Bool) {
        self.autoApplyEnabled = autoApplyEnabled
        self.reapplyAfterWake = reapplyAfterWake
    }
}

public enum AutomationSkipReason: Hashable, Sendable, CustomStringConvertible {
    case sessionInactive
    case selfInduced
    case paused
    case noTopologyChange
    case triggerDisabled
    case configurationUnavailable
    case noMatchingRule
    case alreadyAppliedForTopology
    case alreadyMatches(profileID: UUID)
    case circuitBreakerTripped

    public var description: String {
        switch self {
        case .sessionInactive: "user session is not active"
        case .selfInduced: "change caused by an apply"
        case .paused: "automation is paused after repeated applies"
        case .noTopologyChange: "connected displays did not change"
        case .triggerDisabled: "this trigger is turned off"
        case .configurationUnavailable: "current configuration is not available"
        case .noMatchingRule: "no rule matches the connected displays"
        case .alreadyAppliedForTopology: "already applied for these displays"
        case .alreadyMatches: "the layout is already active"
        case .circuitBreakerTripped: "too many automatic applies, automation paused"
        }
    }
}

public enum AutomationDecision: Hashable, Sendable {
    case apply(profileID: UUID, trigger: AutomationTrigger, ruleID: UUID?)
    case skip(AutomationSkipReason)
}

/// Decides when automation applies a layout, and prevents loops. Pure and deterministic: time is passed in.
public struct AutomationPolicy: Sendable {
    public struct PreSleepState: Hashable, Sendable {
        public var signature: TopologySignature
        public var profileID: UUID?
    }

    /// Events until this long after an apply ends are treated as caused by the apply.
    public var suppressionTail: TimeInterval = 3
    /// More than this many automatic applies inside `breakerWindow` pauses automation.
    public var breakerLimit = 3
    public var breakerWindow: TimeInterval = 120

    public private(set) var lastStableSignature: TopologySignature?
    /// Increments each time the stable set of connected displays changes.
    public private(set) var topologyEntry = 0
    /// The topology entry for which automation already acted (applied or found the layout correct).
    public private(set) var handledEntry: Int?
    public private(set) var recentAutoApplies: [Date] = []
    public private(set) var applyInProgress = false
    public private(set) var suppressUntil: Date?
    public private(set) var preSleep: PreSleepState?
    public private(set) var pausedAt: Date?

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    public mutating func evaluate(
        reason: AutomationReason,
        snapshot: SystemSnapshot,
        profiles: [LayoutProfile],
        rules: [AutoApplyRule],
        settings: AutomationSettings,
        sessionActive: Bool,
        now: Date
    ) -> AutomationDecision {
        let signature = snapshot.signature
        guard sessionActive else { return .skip(.sessionInactive) }

        if applyInProgress || (suppressUntil.map { now < $0 } ?? false) {
            updateStableSignature(signature, keepHandledState: true)
            return .skip(.selfInduced)
        }

        if reason == .displayChange {
            guard signature != lastStableSignature else { return .skip(.noTopologyChange) }
        }
        updateStableSignature(signature, keepHandledState: false)

        if let pausedAt {
            let windowOver = now >= pausedAt.addingTimeInterval(breakerWindow)
            guard reason == .displayChange, windowOver else { return .skip(.paused) }
            resume()
        }

        let trigger = reason.trigger
        let triggerEnabled = trigger == .wake ? settings.reapplyAfterWake : settings.autoApplyEnabled
        guard triggerEnabled else { return .skip(.triggerDisabled) }
        guard snapshot.parsedList != nil else { return .skip(.configurationUnavailable) }

        var target: (profileID: UUID, ruleID: UUID?)?
        if let match = RuleMatcher.bestMatch(trigger: trigger, rules: rules, profiles: profiles, snapshot: snapshot) {
            target = (match.profile.id, match.rule.id)
        } else if trigger == .wake, let preSleep, preSleep.signature == signature,
                  let profileID = preSleep.profileID, profiles.contains(where: { $0.id == profileID }) {
            target = (profileID, nil)
        }
        guard let target, let profile = profiles.first(where: { $0.id == target.profileID }) else {
            return .skip(.noMatchingRule)
        }

        if trigger != .wake, handledEntry == topologyEntry {
            return .skip(.alreadyAppliedForTopology)
        }

        if LayoutComparator.compare(profile: profile, snapshot: snapshot, scope: .fullLayout).isMatch {
            handledEntry = topologyEntry
            return .skip(.alreadyMatches(profileID: profile.id))
        }

        recentAutoApplies.removeAll { now.timeIntervalSince($0) > breakerWindow }
        if recentAutoApplies.count >= breakerLimit {
            pausedAt = now
            return .skip(.circuitBreakerTripped)
        }

        recentAutoApplies.append(now)
        handledEntry = topologyEntry
        return .apply(profileID: profile.id, trigger: trigger, ruleID: target.ruleID)
    }

    /// Call before any apply (automatic or manual) starts.
    public mutating func applyDidStart() {
        applyInProgress = true
    }

    /// Call after any apply ends, with the signature captured after it.
    public mutating func applyDidFinish(signature: TopologySignature?, now: Date) {
        applyInProgress = false
        suppressUntil = now.addingTimeInterval(suppressionTail)
        if let signature { updateStableSignature(signature, keepHandledState: true) }
    }

    public mutating func recordSleep(signature: TopologySignature, matchedProfileID: UUID?) {
        preSleep = PreSleepState(signature: signature, profileID: matchedProfileID)
    }

    /// Clears the circuit breaker (for example when the user turns Auto Apply on again).
    public mutating func resume() {
        pausedAt = nil
        recentAutoApplies.removeAll()
    }

    private mutating func updateStableSignature(_ signature: TopologySignature, keepHandledState: Bool) {
        guard signature != lastStableSignature else { return }
        let wasHandled = handledEntry == topologyEntry
        lastStableSignature = signature
        topologyEntry += 1
        if keepHandledState, wasHandled { handledEntry = topologyEntry }
    }
}

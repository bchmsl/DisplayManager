import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct AutomationPolicyTests {
    let desk = deskProfile()
    let enabled = AutomationSettings(autoApplyEnabled: true, reapplyAfterWake: true)

    let rules = [
        AutoApplyRule(profileID: deskProfile().id, connectionRequirements: [ConnectionRequirement(persistentID: TestIDs.external, connection: usbC(3))]),
    ]

    /// Desk displays connected on `port`, with a layout that is not the Desk layout.
    func customSnapshot(port: Int = 3) -> SystemSnapshot {
        makeSnapshot(displays: [.external(connection: .external(usbC(port))), .builtIn()], configuration: fixtureConfiguration)
    }

    func deskSnapshot() -> SystemSnapshot {
        makeSnapshot(displays: [.external(), .builtIn()], configuration: deskConfiguration)
    }

    func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

    func evaluate(
        _ policy: inout AutomationPolicy,
        _ reason: AutomationReason,
        _ snapshot: SystemSnapshot,
        at seconds: Double,
        settings: AutomationSettings? = nil,
        rules: [AutoApplyRule]? = nil,
        sessionActive: Bool = true
    ) -> AutomationDecision {
        policy.evaluate(
            reason: reason, snapshot: snapshot, profiles: [desk], rules: rules ?? self.rules,
            settings: settings ?? enabled, sessionActive: sessionActive, now: time(seconds))
    }

    @Test func appliesOnLaunchWhenRuleMatches() {
        var policy = AutomationPolicy()
        let decision = evaluate(&policy, .launch, customSnapshot(), at: 0)
        #expect(decision == .apply(profileID: desk.id, trigger: .launch, ruleID: rules[0].id))
    }

    @Test func skipsWhenLayoutAlreadyMatches() {
        var policy = AutomationPolicy()
        #expect(evaluate(&policy, .launch, deskSnapshot(), at: 0) == .skip(.alreadyMatches(profileID: desk.id)))
    }

    @Test func appliesOncePerTopology() {
        var policy = AutomationPolicy()
        let snapshot = customSnapshot()
        guard case .apply = evaluate(&policy, .displayChange, snapshot, at: 0) else {
            Issue.record("expected apply")
            return
        }
        policy.applyDidStart()
        policy.applyDidFinish(signature: snapshot.signature, now: time(2))
        // Same displays, after the suppression tail: nothing changed.
        #expect(evaluate(&policy, .displayChange, snapshot, at: 10) == .skip(.noTopologyChange))
        // A launch-style re-evaluation of the same topology does not apply again either.
        #expect(evaluate(&policy, .launch, snapshot, at: 11) == .skip(.alreadyAppliedForTopology))
    }

    @Test func userChangesAfterAutoApplyAreRespected() {
        var policy = AutomationPolicy()
        _ = evaluate(&policy, .displayChange, deskSnapshot(), at: 0)
        // The user rearranges displays by hand: same topology, different layout.
        #expect(evaluate(&policy, .displayChange, customSnapshot(), at: 30) == .skip(.noTopologyChange))
    }

    @Test func newTopologyAppliesAgain() {
        var policy = AutomationPolicy()
        _ = evaluate(&policy, .displayChange, customSnapshot(), at: 0)
        let unplugged = makeSnapshot(displays: [.builtIn()], configuration: [screen(TestIDs.builtIn, res: (1512, 982), hz: 120, origin: (0, 0))])
        #expect(evaluate(&policy, .displayChange, unplugged, at: 20) == .skip(.noMatchingRule))
        #expect(evaluate(&policy, .displayChange, customSnapshot(), at: 40) == .apply(profileID: desk.id, trigger: .displayConnect, ruleID: rules[0].id))
    }

    @Test func eventsDuringAndRightAfterAnApplyAreSelfInduced() {
        var policy = AutomationPolicy()
        policy.applyDidStart()
        #expect(evaluate(&policy, .displayChange, customSnapshot(), at: 0) == .skip(.selfInduced))
        policy.applyDidFinish(signature: customSnapshot().signature, now: time(1))
        #expect(evaluate(&policy, .displayChange, customSnapshot(port: 1), at: 3.5) == .skip(.selfInduced))
        // After the tail, a real change is evaluated. Port 2 does not satisfy the rule.
        #expect(evaluate(&policy, .displayChange, customSnapshot(port: 2), at: 5) == .skip(.noMatchingRule))
    }

    @Test func manualApplyDuringTopologyChangeIsNotUndone() {
        var policy = AutomationPolicy()
        let generic = [AutoApplyRule(profileID: desk.id)]
        #expect(evaluate(&policy, .displayChange, deskSnapshot(), at: 0, rules: generic) == .skip(.alreadyMatches(profileID: desk.id)))
        policy.applyDidStart()
        // The monitor re-enumerates on another port during a manual apply.
        #expect(evaluate(&policy, .displayChange, customSnapshot(port: 1), at: 1, rules: generic) == .skip(.selfInduced))
        policy.applyDidFinish(signature: customSnapshot(port: 1).signature, now: time(2))
        #expect(evaluate(&policy, .launch, customSnapshot(port: 1), at: 10, rules: generic) == .skip(.alreadyAppliedForTopology))
    }

    @Test func settingsGateTriggers() {
        var policy = AutomationPolicy()
        let off = AutomationSettings(autoApplyEnabled: false, reapplyAfterWake: true)
        #expect(evaluate(&policy, .launch, customSnapshot(), at: 0, settings: off) == .skip(.triggerDisabled))
        #expect(evaluate(&policy, .wake, customSnapshot(), at: 1, settings: off) == .apply(profileID: desk.id, trigger: .wake, ruleID: rules[0].id))

        var second = AutomationPolicy()
        let noWake = AutomationSettings(autoApplyEnabled: true, reapplyAfterWake: false)
        #expect(evaluate(&second, .wake, customSnapshot(), at: 0, settings: noWake) == .skip(.triggerDisabled))
        #expect(evaluate(&second, .sessionActive, customSnapshot(), at: 1, settings: noWake) == .skip(.triggerDisabled))
    }

    @Test func inactiveSessionAndMissingConfigurationSkip() {
        var policy = AutomationPolicy()
        #expect(evaluate(&policy, .launch, customSnapshot(), at: 0, sessionActive: false) == .skip(.sessionInactive))
        let noConfig = makeSnapshot(displays: [.external(), .builtIn()], configuration: nil)
        #expect(evaluate(&policy, .launch, noConfig, at: 1) == .skip(.configurationUnavailable))
    }

    @Test func ruleTriggersAreRespected() {
        var policy = AutomationPolicy()
        let launchOnly = [AutoApplyRule(profileID: desk.id, triggers: RuleTriggers(launch: true, displayConnect: false, wake: false))]
        #expect(evaluate(&policy, .displayChange, customSnapshot(), at: 0, rules: launchOnly) == .skip(.noMatchingRule))
    }

    @Test func wakeRestoresPreSleepLayoutWithoutRule() {
        var policy = AutomationPolicy()
        let snapshot = customSnapshot()
        policy.recordSleep(signature: snapshot.signature, matchedProfileID: desk.id)
        #expect(evaluate(&policy, .wake, snapshot, at: 0, rules: []) == .apply(profileID: desk.id, trigger: .wake, ruleID: nil))

        // Different displays after wake: no restore.
        var other = AutomationPolicy()
        other.recordSleep(signature: snapshot.signature, matchedProfileID: desk.id)
        #expect(evaluate(&other, .wake, customSnapshot(port: 1), at: 0, rules: []) == .skip(.noMatchingRule))
    }

    @Test func wakeReappliesEvenForAHandledTopology() {
        var policy = AutomationPolicy()
        _ = evaluate(&policy, .launch, customSnapshot(), at: 0)
        policy.applyDidStart()
        policy.applyDidFinish(signature: customSnapshot().signature, now: time(1))
        #expect(evaluate(&policy, .wake, customSnapshot(), at: 600) == .apply(profileID: desk.id, trigger: .wake, ruleID: rules[0].id))
    }

    @Test func circuitBreakerPausesAndResumes() {
        var policy = AutomationPolicy()
        let generic = [AutoApplyRule(profileID: desk.id)]
        let a = customSnapshot(port: 3)
        let b = customSnapshot(port: 1)
        #expect(evaluate(&policy, .displayChange, a, at: 0, rules: generic) == .apply(profileID: desk.id, trigger: .displayConnect, ruleID: generic[0].id))
        #expect(evaluate(&policy, .displayChange, b, at: 10, rules: generic) == .apply(profileID: desk.id, trigger: .displayConnect, ruleID: generic[0].id))
        #expect(evaluate(&policy, .displayChange, a, at: 20, rules: generic) == .apply(profileID: desk.id, trigger: .displayConnect, ruleID: generic[0].id))
        #expect(evaluate(&policy, .displayChange, b, at: 30, rules: generic) == .skip(.circuitBreakerTripped))
        #expect(policy.isPaused)
        #expect(evaluate(&policy, .displayChange, a, at: 40, rules: generic) == .skip(.paused))
        #expect(evaluate(&policy, .launch, a, at: 200, rules: generic) == .skip(.paused))
        // A real topology change after the window resumes automation.
        #expect(evaluate(&policy, .displayChange, b, at: 200, rules: generic) == .apply(profileID: desk.id, trigger: .displayConnect, ruleID: generic[0].id))
        #expect(!policy.isPaused)
    }

    @Test func resumeClearsTheBreaker() {
        var policy = AutomationPolicy()
        let generic = [AutoApplyRule(profileID: desk.id)]
        for (index, port) in [3, 1, 3, 1].enumerated() {
            _ = evaluate(&policy, .displayChange, customSnapshot(port: port), at: Double(index) * 10, rules: generic)
        }
        #expect(policy.isPaused)
        policy.resume()
        #expect(evaluate(&policy, .displayChange, customSnapshot(port: 2), at: 50, rules: generic) == .apply(profileID: desk.id, trigger: .displayConnect, ruleID: generic[0].id))
    }
}

import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct DisplayResolverTests {
    @Test func matchesSameUUIDCaseInsensitively() {
        let live = [LiveDisplay.external(id: TestIDs.external.lowercased()), .builtIn()]
        let resolution = DisplayResolver.resolve(profile: deskProfile(), snapshot: makeSnapshot(displays: live, configuration: nil))
        #expect(resolution.liveID(forSaved: TestIDs.external) == TestIDs.external.lowercased())
        #expect(resolution.liveID(forSaved: TestIDs.builtIn) == TestIDs.builtIn)
        #expect(resolution.unresolvedSavedIDs.isEmpty)
    }

    @Test func fallsBackToBuiltInAndHardwareIdentity() {
        let newBuiltIn = "11111111-AAAA-BBBB-CCCC-000000000000"
        let newExternal = "22222222-AAAA-BBBB-CCCC-000000000000"
        let live = [LiveDisplay.builtIn(id: newBuiltIn), LiveDisplay.external(id: newExternal)]
        let resolution = DisplayResolver.resolve(saved: deskProfile().displays, live: live)
        #expect(resolution.liveID(forSaved: TestIDs.builtIn) == newBuiltIn)
        #expect(resolution.liveID(forSaved: TestIDs.external) == newExternal)
    }

    @Test func zeroSerialIsNotAnIdentity() {
        var saved = LiveDisplay.external(serial: 0).displayInfo
        saved.persistentID = TestIDs.third
        let resolution = DisplayResolver.resolve(saved: [saved], live: [.external(serial: 0)])
        #expect(resolution.unresolvedSavedIDs == [TestIDs.third])
    }

    @Test func duplicateIdentitiesStayUnresolved() {
        var first = LiveDisplay.external().displayInfo
        first.persistentID = "S1"
        var second = first
        second.persistentID = "S2"
        let resolution = DisplayResolver.resolve(saved: [first, second], live: [.external()])
        #expect(Set(resolution.unresolvedSavedIDs) == ["S1", "S2"])

        let twoLive = DisplayResolver.resolve(saved: [first], live: [.external(id: "L1"), .external(id: "L2")])
        #expect(twoLive.unresolvedSavedIDs == ["S1"])
    }

    @Test func eachLiveDisplayIsUsedOnce() {
        // Saved external by UUID takes the live display; a second saved record with the same hardware identity stays unresolved.
        var copy = LiveDisplay.external().displayInfo
        copy.persistentID = "S2"
        let resolution = DisplayResolver.resolve(saved: [LiveDisplay.external().displayInfo, copy], live: [.external()])
        #expect(resolution.liveID(forSaved: TestIDs.external) == TestIDs.external)
        #expect(resolution.unresolvedSavedIDs == ["S2"])
        #expect(resolution.resolvedLiveIDs == [TestIDs.external])
    }

    @Test func missingDisplayIsUnresolved() {
        let resolution = DisplayResolver.resolve(profile: deskProfile(), snapshot: makeSnapshot(displays: [.builtIn()], configuration: nil))
        #expect(resolution.unresolvedSavedIDs == [TestIDs.external])
    }
}

@Suite struct LayoutComparatorTests {
    let displays = [LiveDisplay.external(), LiveDisplay.builtIn()]

    @Test func identicalLayoutMatches() {
        let snapshot = makeSnapshot(displays: displays, configuration: deskConfiguration)
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .fullLayout) == .match)
    }

    @Test func screenOrderDoesNotMatter() {
        let snapshot = makeSnapshot(displays: displays, configuration: deskConfiguration.reversed())
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .fullLayout).isMatch)
    }

    @Test func originToleranceIsTwoPoints() {
        var nudged = deskConfiguration
        nudged[1].origin = DisplayPoint(x: 3010, y: 606)
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: makeSnapshot(displays: displays, configuration: nudged), scope: .fullLayout).isMatch)

        nudged[1].origin = DisplayPoint(x: 3011, y: 608)
        let comparison = LayoutComparator.compare(profile: deskProfile(), snapshot: makeSnapshot(displays: displays, configuration: nudged), scope: .fullLayout)
        #expect(comparison.differences == [.origin(name: "Built-in Retina Display", expected: DisplayPoint(x: 3008, y: 608), actual: DisplayPoint(x: 3011, y: 608))])
    }

    @Test func reportsFieldDifferences() {
        var changed = deskConfiguration
        changed[0].resolution = DisplaySize(width: 1920, height: 1080)
        changed[0].refreshRate = 30
        changed[0].scaling = false
        changed[0].rotation = 90
        changed[0].colorDepth = 10
        let differences = LayoutComparator.compare(profile: deskProfile(), snapshot: makeSnapshot(displays: displays, configuration: changed), scope: .fullLayout).differences
        #expect(differences.count == 5)
        #expect(differences.contains(.resolution(name: "Mi Monitor", expected: DisplaySize(width: 3008, height: 1692), actual: DisplaySize(width: 1920, height: 1080))))
        #expect(differences.contains(.refreshRate(name: "Mi Monitor", expected: 60, actual: 30)))
        #expect(differences.contains(.scaling(name: "Mi Monitor", expected: true, actual: false)))
        #expect(differences.contains(.rotation(name: "Mi Monitor", expected: 0, actual: 90)))
        #expect(differences.contains(.colorDepth(name: "Mi Monitor", expected: 8, actual: 10)))
    }

    @Test func missingLiveRefreshRateIsIgnored() {
        var live = deskConfiguration
        live[0].refreshRate = nil
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: makeSnapshot(displays: displays, configuration: live), scope: .fullLayout).isMatch)
    }

    @Test func missingRotationEqualsZero() {
        var profile = deskProfile()
        profile.screens[0].rotation = nil
        #expect(LayoutComparator.compare(profile: profile, snapshot: makeSnapshot(displays: displays, configuration: deskConfiguration), scope: .fullLayout).isMatch)
    }

    @Test func extraDisplayOnlyCountsForFullLayout() {
        let third = LiveDisplay.external(id: TestIDs.third, name: "Side", serial: 3)
        let configuration = deskConfiguration + [screen(TestIDs.third, res: (1920, 1080), origin: (-1920, 0))]
        let snapshot = makeSnapshot(displays: displays + [third], configuration: configuration)
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .fullLayout).differences == [.extraDisplay(name: "Side")])
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .profileDisplaysOnly).isMatch)
    }

    @Test func missingDisplayIsReported() {
        let snapshot = makeSnapshot(displays: [.builtIn()], configuration: [screen(TestIDs.builtIn, res: (1512, 982), hz: 120, origin: (0, 0))])
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .profileDisplaysOnly).differences.contains(.displayNotConnected(name: "Mi Monitor")))
    }

    @Test func disabledDisplays() {
        var profile = deskProfile()
        profile.screens[1] = disabledScreen(TestIDs.builtIn)

        let stillOn = makeSnapshot(displays: displays, configuration: deskConfiguration)
        #expect(LayoutComparator.compare(profile: profile, snapshot: stillOn, scope: .fullLayout).differences == [.shouldBeDisabled(name: "Built-in Retina Display")])

        let off = makeSnapshot(displays: displays, configuration: [deskConfiguration[0], disabledScreen(TestIDs.builtIn)])
        #expect(LayoutComparator.compare(profile: profile, snapshot: off, scope: .fullLayout).isMatch)

        // Clamshell: the disabled display is not listed at all.
        let clamshell = makeSnapshot(displays: [.external()], configuration: [deskConfiguration[0]])
        #expect(LayoutComparator.compare(profile: profile, snapshot: clamshell, scope: .fullLayout).isMatch)

        let enabledProfile = deskProfile()
        #expect(LayoutComparator.compare(profile: enabledProfile, snapshot: off, scope: .fullLayout).differences == [.shouldBeEnabled(name: "Built-in Retina Display")])
    }

    @Test func mirroring() throws {
        let mirrored = try ListOutputParser.parse(fixture("list-synthetic-mirrored.txt")).configuration
        let snapshot = makeSnapshot(displays: displays, configuration: mirrored)
        let comparison = LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .fullLayout)
        #expect(comparison.differences.contains(.mirroringDiffers(names: ["Mi Monitor"])))

        let mirrorProfile = LayoutProfile(
            name: "Mirror", createdAt: .distantPast, updatedAt: .distantPast,
            screens: mirrored, displays: deskProfile().displays)
        #expect(LayoutComparator.compare(profile: mirrorProfile, snapshot: snapshot, scope: .fullLayout).isMatch)
    }

    @Test func unavailableConfiguration() {
        let snapshot = makeSnapshot(displays: displays, configuration: nil)
        #expect(LayoutComparator.compare(profile: deskProfile(), snapshot: snapshot, scope: .fullLayout) == .mismatch([.configurationUnavailable]))
    }

    @Test func currentProfileIsFirstFullMatch() {
        let desk = deskProfile()
        var deskCopy = deskProfile(id: UUID())
        deskCopy.name = "Desk copy"
        let macOnly = macBookOnlyProfile()
        let snapshot = makeSnapshot(displays: displays, configuration: deskConfiguration)
        #expect(LayoutComparator.currentProfile(in: [macOnly, desk, deskCopy], snapshot: snapshot)?.id == desk.id)
        #expect(LayoutComparator.currentProfile(in: [deskCopy, desk], snapshot: snapshot)?.id == deskCopy.id)

        // Custom: nothing matches.
        let custom = makeSnapshot(displays: displays, configuration: fixtureConfiguration)
        #expect(LayoutComparator.currentProfile(in: [macOnly, desk], snapshot: custom) == nil)

        // A subset profile does not match while an extra display is on.
        #expect(LayoutComparator.currentProfile(in: [macOnly], snapshot: snapshot) == nil)
    }
}

@Suite struct RuleMatcherTests {
    let desk = deskProfile()

    func rule(ports: [ConnectionFingerprint] = [], triggers: RuleTriggers = RuleTriggers(), enabled: Bool = true, profile: LayoutProfile? = nil) -> AutoApplyRule {
        AutoApplyRule(
            profileID: (profile ?? desk).id,
            isEnabled: enabled,
            connectionRequirements: ports.map { ConnectionRequirement(persistentID: TestIDs.external, connection: $0) },
            triggers: triggers)
    }

    func snapshot(port: ConnectionState = .external(usbC(3)), extra: [LiveDisplay] = []) -> SystemSnapshot {
        makeSnapshot(displays: [.external(connection: port), .builtIn()] + extra, configuration: fixtureConfiguration)
    }

    @Test func portRequirementMatchesSamePort() {
        #expect(RuleMatcher.evaluate(rule: rule(ports: [usbC(3)]), profile: desk, snapshot: snapshot()).isSatisfied)
    }

    @Test func portRequirementFailsOnOtherPort() {
        let evaluation = RuleMatcher.evaluate(rule: rule(ports: [usbC(3)]), profile: desk, snapshot: snapshot(port: .external(usbC(1))))
        #expect(evaluation.mismatches == [.portDiffers(name: "Mi Monitor", expected: usbC(3), actual: .external(usbC(1)))])
        #expect(evaluation.mismatches[0].description == "Mi Monitor is connected to USB-C Port 1, not USB-C Port 3")
    }

    @Test func tunnelFlagIsPartOfThePort() {
        #expect(!RuleMatcher.evaluate(rule: rule(ports: [usbC(3)]), profile: desk, snapshot: snapshot(port: .external(usbC(3, tunneled: true)))).isSatisfied)
    }

    @Test func unidentifiedPortNeverSatisfies() {
        for reason in [UnidentifiedReason.noTransport, .ambiguous, .noPortInfo, .topologyUnavailable] {
            let evaluation = RuleMatcher.evaluate(rule: rule(ports: [usbC(3)]), profile: desk, snapshot: snapshot(port: .unidentified(reason)))
            #expect(!evaluation.isSatisfied)
            #expect(evaluation.mismatches.first?.description.contains(reason.userMessage) == true)
        }
    }

    @Test func differentMacModelIsExplained() {
        let evaluation = RuleMatcher.evaluate(rule: rule(ports: [usbC(3, host: "Mac15,3")]), profile: desk, snapshot: snapshot())
        #expect(!evaluation.isSatisfied)
        #expect(evaluation.mismatches[0].description.contains("different Mac model"))
    }

    @Test func ruleWithoutPortsNeedsExactDisplaySet() {
        #expect(RuleMatcher.evaluate(rule: rule(), profile: desk, snapshot: snapshot()).isSatisfied)

        let withExtra = snapshot(extra: [.external(id: TestIDs.third, name: "Side", serial: 3)])
        #expect(RuleMatcher.evaluate(rule: rule(), profile: desk, snapshot: withExtra).mismatches == [.extraDisplayConnected(name: "Side")])

        let missing = makeSnapshot(displays: [.builtIn()], configuration: [])
        #expect(RuleMatcher.evaluate(rule: rule(ports: [usbC(3)]), profile: desk, snapshot: missing).mismatches == [.displayNotConnected(name: "Mi Monitor")])
    }

    @Test func disabledProfileDisplaysMayBeAbsent() {
        var profile = deskProfile()
        profile.screens[1] = disabledScreen(TestIDs.builtIn)
        let clamshell = makeSnapshot(displays: [.external()], configuration: [])
        #expect(RuleMatcher.evaluate(rule: rule(ports: [usbC(3)], profile: profile), profile: profile, snapshot: clamshell).isSatisfied)
    }

    @Test func bestMatchPrefersMoreSpecificRules() {
        let generic = rule()
        let specific = rule(ports: [usbC(3)])
        let other = deskProfile(id: UUID())
        let otherRule = rule(profile: other)
        let best = RuleMatcher.bestMatch(trigger: .displayConnect, rules: [generic, otherRule, specific], profiles: [desk, other], snapshot: snapshot())
        #expect(best?.rule.id == specific.id)
    }

    @Test func bestMatchTieBreaksByProfileOrderThenRuleOrder() {
        let first = deskProfile(id: UUID())
        let second = deskProfile(id: UUID())
        let ruleForSecond = rule(profile: second)
        let ruleForFirst = rule(profile: first)
        let best = RuleMatcher.bestMatch(trigger: .launch, rules: [ruleForSecond, ruleForFirst], profiles: [first, second], snapshot: snapshot())
        #expect(best?.profile.id == first.id)

        let a = rule()
        let b = rule()
        #expect(RuleMatcher.bestMatch(trigger: .launch, rules: [a, b], profiles: [desk], snapshot: snapshot())?.rule.id == a.id)
    }

    @Test func bestMatchSkipsDisabledRulesAndOtherTriggers() {
        let disabled = rule(enabled: false)
        let wakeOnly = rule(triggers: RuleTriggers(launch: false, displayConnect: false, wake: true))
        #expect(RuleMatcher.bestMatch(trigger: .displayConnect, rules: [disabled, wakeOnly], profiles: [desk], snapshot: snapshot()) == nil)
        #expect(RuleMatcher.bestMatch(trigger: .wake, rules: [disabled, wakeOnly], profiles: [desk], snapshot: snapshot())?.rule.id == wakeOnly.id)
        let orphan = AutoApplyRule(profileID: UUID())
        #expect(RuleMatcher.bestMatch(trigger: .launch, rules: [orphan], profiles: [desk], snapshot: snapshot()) == nil)
    }

    @Test func conflictsNeedSameConditionsAndSharedTrigger() {
        let a = rule(ports: [usbC(3)])
        let b = rule(ports: [usbC(3)])
        let otherPort = rule(ports: [usbC(1)])
        let wakeOnly = rule(ports: [usbC(3)], triggers: RuleTriggers(launch: false, displayConnect: false, wake: true))
        let launchOnly = AutoApplyRule(
            profileID: desk.id,
            connectionRequirements: [ConnectionRequirement(persistentID: TestIDs.external, connection: usbC(3))],
            triggers: RuleTriggers(launch: true, displayConnect: false, wake: false))
        let rules = [a, b, otherPort, wakeOnly, launchOnly]
        #expect(Set(RuleMatcher.conflictingRules(for: a, rules: rules, profiles: [desk]).map(\.id)) == [b.id, wakeOnly.id, launchOnly.id])
        #expect(Set(RuleMatcher.conflictingRules(for: wakeOnly, rules: rules, profiles: [desk]).map(\.id)) == [a.id, b.id])
        #expect(RuleMatcher.conflictingRules(for: otherPort, rules: rules, profiles: [desk]).isEmpty)
    }
}

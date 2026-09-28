import Foundation
import Testing
@testable import DisplayManagerCore

private struct CancellingSleeper: Sleeper {
    func sleep(seconds: Double) async throws { throw CancellationError() }
}

@Suite struct LayoutApplierTests {
    let desk = deskProfile()
    let connected: [LiveDisplay] = [.external(), .builtIn()]

    var customSnapshot: SystemSnapshot { makeSnapshot(displays: connected, configuration: fixtureConfiguration) }
    var deskSnapshot: SystemSnapshot { makeSnapshot(displays: connected, configuration: deskConfiguration) }
    var builtInOnly: SystemSnapshot {
        makeSnapshot(displays: [.builtIn()], configuration: [screen(TestIDs.builtIn, res: (1800, 1169), hz: 120, origin: (0, 0))])
    }

    func run(_ control: FakeDisplayControl, policy: ApplyPolicy = .manual, sleeper: RecordingSleeper = RecordingSleeper()) async -> ApplyReport {
        await LayoutApplier(control: control, sleeper: sleeper).apply(profile: desk, policy: policy)
    }

    @Test func alreadyActiveLayoutDoesNothing() async {
        let control = FakeDisplayControl(current: deskSnapshot)
        let report = await run(control)
        #expect(report.result == .alreadyApplied)
        #expect(await control.runArguments.isEmpty)
    }

    @Test func appliesAndVerifies() async throws {
        let control = FakeDisplayControl(current: customSnapshot, runResults: [.init(output: output(), resultingSnapshot: deskSnapshot)])
        let sleeper = RecordingSleeper()
        let report = await run(control, sleeper: sleeper)
        #expect(report.result == .applied(attempts: 1))
        #expect(await control.runArguments == [try CommandBuilder.arguments(for: desk.screens)])
        #expect(await sleeper.delays == [0.75])
        #expect(report.finalSnapshot == deskSnapshot)
    }

    @Test func verificationRechecksOnce() async {
        let control = FakeDisplayControl(current: deskSnapshot, queue: [customSnapshot, customSnapshot])
        let sleeper = RecordingSleeper()
        let report = await run(control, sleeper: sleeper)
        #expect(report.result == .applied(attempts: 1))
        #expect(await sleeper.delays == [0.75, 1.5])
    }

    @Test func verificationFailureRetriesThenFails() async {
        let control = FakeDisplayControl(current: customSnapshot)
        let sleeper = RecordingSleeper()
        let report = await run(control, sleeper: sleeper)
        #expect(report.result.failure?.kind == .verificationFailed)
        #expect(report.result == .failed(report.result.failure ?? ApplyFailure(kind: .cancelled, message: ""), attempts: 2))
        #expect(await control.runArguments.count == 2)
        #expect(await sleeper.delays == [0.75, 1.5, 1.5, 0.75, 1.5])
        #expect(report.result.failure?.details.contains("Mi Monitor position is (-592,-1692), expected (0,0)") == true)
    }

    @Test func missingDisplayFailsManualApplyImmediately() async {
        let control = FakeDisplayControl(current: builtInOnly)
        let report = await run(control)
        #expect(report.result.failure?.kind == .displayNotConnected)
        #expect(report.result.failure?.message == "Mi Monitor is not connected.")
        #expect(await control.runArguments.isEmpty)
    }

    @Test func missingDisplayMessageListsOtherConnectedDisplays() async {
        let other = LiveDisplay.external(id: TestIDs.third, name: "Dell U2720Q", product: 1, serial: 99)
        let control = FakeDisplayControl(current: makeSnapshot(displays: [.builtIn(), other], configuration: []))
        let report = await run(control)
        #expect(report.result.failure?.message == "Mi Monitor is not connected. Connected: Dell U2720Q.")
    }

    @Test func automaticApplyWaitsForAWakingDisplay() async {
        let control = FakeDisplayControl(
            current: customSnapshot, queue: [builtInOnly],
            runResults: [.init(output: output(), resultingSnapshot: deskSnapshot)])
        let sleeper = RecordingSleeper()
        let report = await run(control, policy: .automatic, sleeper: sleeper)
        #expect(report.result == .applied(attempts: 2))
        #expect(await sleeper.delays == [1.5, 0.75])
    }

    @Test func automaticApplyGivesUpAfterBoundedRetries() async {
        let control = FakeDisplayControl(current: builtInOnly)
        let sleeper = RecordingSleeper()
        let report = await run(control, policy: .automatic, sleeper: sleeper)
        #expect(report.result.failure?.kind == .displayNotConnected)
        if case .failed(_, let attempts) = report.result { #expect(attempts == 4) }
        #expect(await sleeper.delays == [1.5, 3, 5])
        #expect(await control.snapshotCount == 4)
        #expect(report.attempts.count == 4)
    }

    @Test func unsupportedModeIsCaughtBeforeRunning() async {
        let parsed = ParsedList(
            screens: [ParsedScreen(
                persistentID: TestIDs.external, modesRotation: 0,
                modes: [DisplayMode(number: 1, resolution: DisplaySize(width: 1920, height: 1080), refreshRate: 60, colorDepth: 8, scaling: false, isCurrent: true)])],
            configuration: fixtureConfiguration, commandLine: "")
        let snapshot = SystemSnapshot(displays: connected, parsedList: parsed, topologyStatus: .available, hostModel: TestIDs.host, capturedAt: .distantPast)
        let control = FakeDisplayControl(current: snapshot)
        let report = await run(control)
        #expect(report.result.failure?.kind == .unsupportedMode)
        #expect(report.result.failure?.message == "3008 × 1692 @ 60 Hz (scaled) is not supported by Mi Monitor.")
        #expect(report.result.failure?.details.contains("1920x1080 @ 60 Hz") == true)
        #expect(await control.runArguments.isEmpty)
    }

    @Test func realModeListPassesThePrecheck() async throws {
        let parsed = try ListOutputParser.parse(fixture("list-builtin-and-external.txt"))
        let snapshot = SystemSnapshot(displays: connected, parsedList: parsed, topologyStatus: .available, hostModel: TestIDs.host, capturedAt: .distantPast)
        let control = FakeDisplayControl(current: snapshot, runResults: [.init(output: output(), resultingSnapshot: deskSnapshot)])
        #expect(await run(control).result == .applied(attempts: 1))
    }

    @Test func processFailureIsReportedWithDetails() async {
        let control = FakeDisplayControl(current: customSnapshot, runResults: [.init(output: output(exit: 1, stderr: "boom"), resultingSnapshot: nil)])
        let report = await run(control)
        #expect(report.result.failure?.kind == .processFailed(exitCode: 1))
        let details = report.result.failure?.details ?? ""
        #expect(details.contains("/opt/homebrew/bin/displayplacer \"id:\(TestIDs.external) "))
        #expect(details.contains("boom"))
        #expect(await control.runArguments.count == 1)
    }

    @Test func automaticApplyRetriesProcessFailure() async {
        let control = FakeDisplayControl(
            current: customSnapshot,
            runResults: [.init(output: output(exit: 1), resultingSnapshot: nil), .init(output: output(), resultingSnapshot: deskSnapshot)])
        #expect(await run(control, policy: .automatic).result == .applied(attempts: 2))
    }

    @Test func displayNotFoundIsRetried() async {
        let control = FakeDisplayControl(
            current: customSnapshot,
            runResults: [.init(output: output(exit: 1, stdout: "Unable to find screen BBBB"), resultingSnapshot: nil), .init(output: output(), resultingSnapshot: deskSnapshot)])
        #expect(await run(control).result == .applied(attempts: 2))
    }

    @Test func unsupportedModeFromOutputStopsImmediately() async {
        let control = FakeDisplayControl(current: customSnapshot, runResults: [.init(output: output(exit: 1, stderr: "could not find res:3008x1692"), resultingSnapshot: nil)])
        let report = await run(control, policy: .automatic)
        #expect(report.result.failure?.kind == .unsupportedMode)
        #expect(await control.runArguments.count == 1)
    }

    @Test func timeoutIsRetriedOnce() async {
        let timedOut = FakeDisplayControl.RunResult(output: output(exit: 15, timedOut: true), resultingSnapshot: nil)
        let control = FakeDisplayControl(current: customSnapshot, runResults: [timedOut, timedOut, timedOut])
        let report = await run(control, policy: .automatic)
        #expect(report.result.failure?.kind == .timedOut)
        #expect(await control.runArguments.count == 2)
    }

    @Test func missingDisplayplacerStopsEvenAutomaticApply() async {
        let control = FakeDisplayControl(current: customSnapshot, snapshotError: .displayplacerNotFound)
        let report = await run(control, policy: .automatic)
        #expect(report.result.failure?.kind == .displayplacerUnavailable)
        #expect(await control.snapshotCount == 1)
    }

    @Test func unreadableConfigurationIsRetriedOnlyAutomatically() async {
        let manual = FakeDisplayControl(current: customSnapshot, snapshotError: .malformedListOutput(detail: "x"))
        #expect(await run(manual).result.failure?.kind == .snapshotFailed)
        #expect(await manual.snapshotCount == 1)

        let automatic = FakeDisplayControl(current: customSnapshot, snapshotError: .malformedListOutput(detail: "x"))
        #expect(await run(automatic, policy: .automatic).result.failure?.kind == .snapshotFailed)
        #expect(await automatic.snapshotCount == 4)
    }

    @Test func cancellationStopsTheApply() async {
        let control = FakeDisplayControl(current: customSnapshot, runResults: [.init(output: output(), resultingSnapshot: deskSnapshot)])
        let report = await LayoutApplier(control: control, sleeper: CancellingSleeper()).apply(profile: desk, policy: .manual)
        #expect(report.result.failure?.kind == .cancelled)
    }

    @Test func reportsEveryAttempt() async {
        let collected = AttemptCollector()
        let control = FakeDisplayControl(current: customSnapshot, runResults: [.init(output: output(), resultingSnapshot: deskSnapshot)])
        let report = await LayoutApplier(control: control, sleeper: RecordingSleeper())
            .apply(profile: desk, policy: .manual) { await collected.add($0) }
        #expect(await collected.records == report.attempts)
        #expect(report.attempts.map(\.summary).last == "verified")
    }
}

private actor AttemptCollector {
    private(set) var records: [ApplyAttemptRecord] = []
    func add(_ record: ApplyAttemptRecord) { records.append(record) }
}

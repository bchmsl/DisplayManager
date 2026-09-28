import Foundation

/// Reads the display state and runs displayplacer. Implemented by the app; faked in tests.
public protocol DisplayControl: Sendable {
    /// Fresh snapshot including the displayplacer configuration. Throws `DisplayManagerError`.
    func captureSnapshot() async throws -> SystemSnapshot
    /// Runs displayplacer with one argument per screen spec. Throws when it cannot be started.
    func runDisplayplacer(arguments: [String]) async throws -> ProcessOutput
    /// Path used for the raw command in failure details.
    var executablePathForDisplay: String? { get async }
}

/// Injectable delay, so tests do not wait.
public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

public struct ApplyPolicy: Hashable, Sendable {
    public var maxAttempts: Int
    /// Delay before attempt 2, 3, …; the last value repeats if needed.
    public var retryDelays: [Double]
    /// Retry when a display of the profile is not connected yet (it may still be waking).
    public var retriesWhenDisplayMissing: Bool
    /// Retry after an unexplained displayplacer failure.
    public var retriesOnProcessFailure: Bool
    public var verifyDelay: Double
    public var recheckDelay: Double

    public init(
        maxAttempts: Int,
        retryDelays: [Double],
        retriesWhenDisplayMissing: Bool,
        retriesOnProcessFailure: Bool,
        verifyDelay: Double = 0.75,
        recheckDelay: Double = 1.5
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelays = retryDelays
        self.retriesWhenDisplayMissing = retriesWhenDisplayMissing
        self.retriesOnProcessFailure = retriesOnProcessFailure
        self.verifyDelay = verifyDelay
        self.recheckDelay = recheckDelay
    }

    /// Connect, wake and launch.
    public static let automatic = ApplyPolicy(
        maxAttempts: 4, retryDelays: [1.5, 3, 5], retriesWhenDisplayMissing: true, retriesOnProcessFailure: true)
    /// Menu, shortcut and Layout Manager.
    public static let manual = ApplyPolicy(
        maxAttempts: 2, retryDelays: [1.5], retriesWhenDisplayMissing: false, retriesOnProcessFailure: false)

    func delay(beforeAttempt attempt: Int) -> Double {
        guard !retryDelays.isEmpty else { return 0 }
        return retryDelays[min(max(attempt - 2, 0), retryDelays.count - 1)]
    }
}

public enum ApplyFailureKind: Hashable, Sendable {
    case displayplacerUnavailable
    case snapshotFailed
    case displayNotConnected
    case unsupportedMode
    case invalidArguments
    case displayNotFound
    case timedOut
    case processFailed(exitCode: Int32)
    case verificationFailed
    case cancelled
}

public struct ApplyFailure: Error, Hashable, Sendable {
    public var kind: ApplyFailureKind
    public var message: String
    public var details: String

    public init(kind: ApplyFailureKind, message: String, details: String = "") {
        self.kind = kind
        self.message = message
        self.details = details
    }
}

public struct ApplyAttemptRecord: Hashable, Sendable {
    public var attempt: Int
    public var maxAttempts: Int
    public var summary: String
    public var arguments: [String]
    public var output: ProcessOutput?

    public init(attempt: Int, maxAttempts: Int, summary: String, arguments: [String] = [], output: ProcessOutput? = nil) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.summary = summary
        self.arguments = arguments
        self.output = output
    }
}

public enum ApplyResult: Hashable, Sendable {
    case applied(attempts: Int)
    case alreadyApplied
    case failed(ApplyFailure, attempts: Int)

    public var failure: ApplyFailure? {
        if case .failed(let failure, _) = self { return failure }
        return nil
    }
}

public struct ApplyReport: Hashable, Sendable {
    public var result: ApplyResult
    public var attempts: [ApplyAttemptRecord]
    /// The last snapshot taken, when any.
    public var finalSnapshot: SystemSnapshot?
}

/// Applies a profile with bounded retries and verification.
///
/// Steps per attempt: snapshot, resolve displays, already-applied check, supported-mode check, run
/// displayplacer, classify, verify (0.75 s, then a re-check after 1.5 s).
public struct LayoutApplier: Sendable {
    public let control: any DisplayControl
    public let sleeper: any Sleeper

    public init(control: any DisplayControl, sleeper: any Sleeper = TaskSleeper()) {
        self.control = control
        self.sleeper = sleeper
    }

    public func apply(
        profile: LayoutProfile,
        policy: ApplyPolicy,
        onAttempt: @Sendable (ApplyAttemptRecord) async -> Void = { _ in }
    ) async -> ApplyReport {
        var records: [ApplyAttemptRecord] = []
        var lastFailure: ApplyFailure?
        var lastSnapshot: SystemSnapshot?
        var ranProcess = false
        var timeoutRetried = false
        let maxAttempts = max(policy.maxAttempts, 1)

        func record(_ attempt: Int, _ summary: String, _ arguments: [String] = [], _ output: ProcessOutput? = nil) async {
            let entry = ApplyAttemptRecord(attempt: attempt, maxAttempts: maxAttempts, summary: summary, arguments: arguments, output: output)
            records.append(entry)
            await onAttempt(entry)
        }
        func report(_ result: ApplyResult) -> ApplyReport {
            ApplyReport(result: result, attempts: records, finalSnapshot: lastSnapshot)
        }

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                do {
                    try await sleeper.sleep(seconds: policy.delay(beforeAttempt: attempt))
                } catch {
                    return report(.failed(ApplyFailure(kind: .cancelled, message: "The apply was cancelled."), attempts: attempt - 1))
                }
            }

            // 1–2. Snapshot.
            let snapshot: SystemSnapshot
            do {
                snapshot = try await control.captureSnapshot()
                lastSnapshot = snapshot
            } catch {
                let failure = Self.failure(forSnapshotError: error)
                lastFailure = failure
                await record(attempt, "snapshot failed: \(failure.message)")
                if failure.kind == .displayplacerUnavailable || !policy.retriesOnProcessFailure {
                    return report(.failed(failure, attempts: attempt))
                }
                continue
            }

            // 3. Resolve displays.
            let resolution = DisplayResolver.resolve(profile: profile, snapshot: snapshot)
            let missing = Set(profile.enabledDisplayIDs.filter { resolution.liveID(forSaved: $0) == nil })
            if !missing.isEmpty {
                let failure = Self.notConnectedFailure(profile: profile, missing: missing, resolution: resolution, snapshot: snapshot)
                lastFailure = failure
                await record(attempt, failure.message)
                if policy.retriesWhenDisplayMissing { continue }
                return report(.failed(failure, attempts: attempt))
            }

            // 5. Already matches (checked before the mode check so a current layout never fails).
            if LayoutComparator.compare(profile: profile, snapshot: snapshot, scope: .profileDisplaysOnly).isMatch {
                await record(attempt, ranProcess ? "layout is active" : "layout already active, nothing to do")
                return report(ranProcess ? .applied(attempts: attempt) : .alreadyApplied)
            }

            // 4. Supported modes.
            if let failure = Self.unsupportedModeFailure(profile: profile, resolution: resolution, snapshot: snapshot) {
                await record(attempt, failure.message)
                return report(.failed(failure, attempts: attempt))
            }

            // 6. Run.
            let arguments: [String]
            do {
                arguments = try CommandBuilder.applyArguments(for: profile, resolution: resolution)
            } catch {
                let failure = ApplyFailure(kind: .invalidArguments, message: "The layout contains invalid settings.", details: "\(error)")
                await record(attempt, failure.message)
                return report(.failed(failure, attempts: attempt))
            }
            let output: ProcessOutput
            do {
                output = try await control.runDisplayplacer(arguments: arguments)
                ranProcess = true
            } catch {
                let failure = Self.failure(forSnapshotError: error)
                await record(attempt, "could not run displayplacer: \(failure.message)", arguments)
                return report(.failed(failure, attempts: attempt))
            }

            // 7. Classify.
            let outcome = RunOutcome.classify(output)
            let command = CommandBuilder.rawCommand(executablePath: await control.executablePathForDisplay, arguments: arguments)
            let processDetails = "Command:\n\(command)\n\nExit code: \(output.exitCode)\nOutput:\n\(output.combinedOutput.isEmpty ? "(none)" : output.combinedOutput)"
            await record(attempt, "displayplacer finished: \(outcome) in \(String(format: "%.2f", output.duration)) s", arguments, output)

            switch outcome {
            case .success:
                // 8. Verify.
                var differences: [LayoutDifference] = []
                for delay in [policy.verifyDelay, policy.recheckDelay] {
                    do {
                        try await sleeper.sleep(seconds: delay)
                    } catch {
                        return report(.failed(ApplyFailure(kind: .cancelled, message: "The apply was cancelled."), attempts: attempt))
                    }
                    guard let verifySnapshot = try? await control.captureSnapshot() else { continue }
                    lastSnapshot = verifySnapshot
                    let comparison = LayoutComparator.compare(profile: profile, snapshot: verifySnapshot, scope: .profileDisplaysOnly)
                    if comparison.isMatch {
                        await record(attempt, "verified")
                        return report(.applied(attempts: attempt))
                    }
                    differences = comparison.differences
                }
                let failure = ApplyFailure(
                    kind: .verificationFailed,
                    message: "The layout did not take effect.",
                    details: "Differences:\n" + differences.map { "• \($0)" }.joined(separator: "\n") + "\n\n" + processDetails)
                lastFailure = failure
                await record(attempt, "verification failed: " + differences.map(\.description).joined(separator: "; "))
            case .displayNotFound:
                lastFailure = ApplyFailure(kind: .displayNotFound, message: "displayplacer could not find one of the displays.", details: processDetails)
            case .unsupportedMode:
                return report(.failed(ApplyFailure(kind: .unsupportedMode, message: "A display does not support the saved mode.", details: processDetails), attempts: attempt))
            case .invalidArguments:
                return report(.failed(ApplyFailure(kind: .invalidArguments, message: "displayplacer rejected the layout settings.", details: processDetails), attempts: attempt))
            case .timedOut:
                let failure = ApplyFailure(kind: .timedOut, message: "displayplacer did not respond in time.", details: processDetails)
                lastFailure = failure
                if timeoutRetried { return report(.failed(failure, attempts: attempt)) }
                timeoutRetried = true
            case .failed(let exitCode):
                let failure = ApplyFailure(kind: .processFailed(exitCode: exitCode), message: "displayplacer failed (exit code \(exitCode)).", details: processDetails)
                lastFailure = failure
                if !policy.retriesOnProcessFailure { return report(.failed(failure, attempts: attempt)) }
            }
        }
        let failure = lastFailure ?? ApplyFailure(kind: .verificationFailed, message: "The layout could not be applied.")
        return report(.failed(failure, attempts: maxAttempts))
    }

    // MARK: Failure helpers

    static func failure(forSnapshotError error: Error) -> ApplyFailure {
        switch error {
        case let error as DisplayManagerError:
            switch error {
            case .displayplacerNotFound, .unsupportedDisplayplacerVersion, .executableUnavailable:
                return ApplyFailure(kind: .displayplacerUnavailable, message: error.userMessage, details: error.diagnosticDetail ?? "")
            case .processTimedOut:
                return ApplyFailure(kind: .timedOut, message: error.userMessage)
            default:
                return ApplyFailure(kind: .snapshotFailed, message: error.userMessage, details: error.diagnosticDetail ?? "")
            }
        case is CancellationError:
            return ApplyFailure(kind: .cancelled, message: "The apply was cancelled.")
        default:
            return ApplyFailure(kind: .snapshotFailed, message: "Couldn't read the current display configuration.", details: "\(error)")
        }
    }

    static func notConnectedFailure(profile: LayoutProfile, missing: Set<String>, resolution: DisplayResolution, snapshot: SystemSnapshot) -> ApplyFailure {
        let missingNames = profile.enabledDisplayIDs.filter(missing.contains).map { profile.displayInfo(for: $0).name }
        var seen = Set<String>()
        let uniqueNames = missingNames.filter { seen.insert($0).inserted }
        let resolvedLive = Set(resolution.resolvedLiveIDs.map { $0.lowercased() })
        let others = snapshot.externalDisplays.filter { !resolvedLive.contains($0.persistentID.lowercased()) }.map(\.name)
        let verb = uniqueNames.count == 1 ? "is" : "are"
        var message = "\(uniqueNames.joined(separator: ", ")) \(verb) not connected."
        if !others.isEmpty { message += " Connected: \(others.joined(separator: ", "))." }
        return ApplyFailure(kind: .displayNotConnected, message: message)
    }

    static func unsupportedModeFailure(profile: LayoutProfile, resolution: DisplayResolution, snapshot: SystemSnapshot) -> ApplyFailure? {
        for screen in profile.screens where screen.enabled {
            guard let size = screen.resolution,
                  let savedID = screen.primaryID,
                  let liveID = resolution.liveID(forSaved: savedID),
                  let parsed = snapshot.parsedList?.screen(persistentID: liveID),
                  !parsed.modes.isEmpty,
                  (parsed.modesRotation ?? 0) == screen.effectiveRotation
            else { continue }
            let supported = parsed.modes.contains { mode in
                mode.resolution == size
                    && (screen.refreshRate == nil || mode.refreshRate == nil || mode.refreshRate == screen.refreshRate)
                    && (screen.scaling == nil || mode.scaling == screen.scaling)
            }
            if !supported {
                let name = profile.displayInfo(for: savedID).name
                let hz = screen.refreshRate.map { " @ \($0) Hz" } ?? ""
                let scaled = screen.scaling == true ? " (scaled)" : ""
                return ApplyFailure(
                    kind: .unsupportedMode,
                    message: "\(size.width) × \(size.height)\(hz)\(scaled) is not supported by \(name).",
                    details: "Supported modes:\n" + parsed.modes.map { mode in
                        "\(mode.resolution)\(mode.refreshRate.map { " @ \($0) Hz" } ?? "")\(mode.scaling ? " scaled" : "")"
                    }.joined(separator: "\n"))
            }
        }
        return nil
    }
}

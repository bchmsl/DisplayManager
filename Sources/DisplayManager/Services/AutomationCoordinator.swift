import DisplayManagerCore
import Foundation

/// Turns display, wake and session events into automation decisions.
///
/// events → debounce 1 s → (wake: settle delay) → stable topology → fresh snapshot → AutomationPolicy → apply.
/// All waits are cancellable `Task.sleep` calls; nothing blocks the main thread.
@MainActor
final class AutomationCoordinator {
    static let debounceSeconds = 1.0
    static let sampleIntervalSeconds = 0.75
    static let maxStabilityConnect = 8.0
    static let maxStabilityWake = 15.0
    /// Extra time for a new external display to get its port transport, once the display set is stable.
    static let portGraceSeconds = 2.0

    private weak var model: AppModel?
    private var policy = AutomationPolicy()
    private var pipeline: Task<Void, Never>?
    private var pendingReason: AutomationReason?
    private var sessionActive = true

    init(model: AppModel) {
        self.model = model
    }

    var isPaused: Bool { policy.isPaused }

    func start() {
        schedule(.launch)
    }

    func handle(_ event: DisplayEvent) {
        switch event {
        case .topologyChanged(let source):
            Log.info(.displays, "Display connection change (\(source))")
            schedule(.displayChange)
        case .layoutChanged:
            schedule(.displayChange)
        case .didWake:
            Log.info(.automation, "Woke from sleep")
            schedule(.wake)
        case .sessionBecameActive:
            Log.info(.automation, "User session became active")
            sessionActive = true
            schedule(.sessionActive)
        case .sessionResignedActive:
            Log.info(.automation, "User session resigned active")
            sessionActive = false
            cancelPending()
        case .willSleep:
            cancelPending()
            model?.applyCoordinator.cancelAutomatic()
            if let model, let snapshot = model.snapshot {
                policy.recordSleep(signature: snapshot.signature, matchedProfileID: model.currentProfileID)
            }
            Log.info(.automation, "Going to sleep; pending automation cancelled")
        }
    }

    /// The user turned Auto Apply on again: clear the circuit breaker.
    func resume() {
        guard policy.isPaused else { return }
        policy.resume()
        model?.setAutomationPaused(false)
        Log.notice(.automation, "Automation resumed")
    }

    // MARK: Apply bookkeeping (manual and automatic applies)

    func applyDidStart() {
        policy.applyDidStart()
    }

    func applyDidFinish(signature: TopologySignature?) {
        policy.applyDidFinish(signature: signature, now: Date())
    }

    // MARK: Pipeline

    private func cancelPending() {
        pipeline?.cancel()
        pipeline = nil
        pendingReason = nil
    }

    private func schedule(_ reason: AutomationReason) {
        let merged = Self.merge(pendingReason, reason)
        pendingReason = merged
        pipeline?.cancel()
        pipeline = Task { [weak self] in
            await self?.run(merged)
        }
    }

    /// Wake outranks everything, because displays re-enumerate right after wake.
    private static func merge(_ pending: AutomationReason?, _ new: AutomationReason) -> AutomationReason {
        func rank(_ reason: AutomationReason) -> Int {
            switch reason {
            case .displayChange: 0
            case .launch: 1
            case .sessionActive: 2
            case .wake: 3
            }
        }
        guard let pending else { return new }
        return rank(new) >= rank(pending) ? new : pending
    }

    private func run(_ reason: AutomationReason) async {
        guard let model else { return }
        do {
            try await Task.sleep(for: .seconds(Self.debounceSeconds))
            let isWake = reason == .wake || reason == .sessionActive
            if isWake, model.settleDelaySeconds > 0 {
                try await Task.sleep(for: .seconds(model.settleDelaySeconds))
            }
            let stable = try await waitForStableTopology(maxWait: isWake ? Self.maxStabilityWake : Self.maxStabilityConnect)
            try Task.checkCancellation()
            pendingReason = nil

            // An apply is running: its own result updates the snapshot and the policy.
            guard !model.applyCoordinator.isRunning else { return }

            let snapshot = await model.refreshSnapshot()
            try Task.checkCancellation()
            guard stable else {
                Log.warning(.automation, "Displays were not ready; status refreshed without applying")
                return
            }
            guard !model.applyCoordinator.isRunning else { return }
            evaluate(reason, snapshot: snapshot)
        } catch {
            // Cancelled by a newer event, sleep or session change.
        }
    }

    private func evaluate(_ reason: AutomationReason, snapshot: SystemSnapshot) {
        guard let model else { return }
        let settings = AutomationSettings(autoApplyEnabled: model.autoApplyEnabled, reapplyAfterWake: model.reapplyAfterWake)
        let decision = policy.evaluate(
            reason: reason, snapshot: snapshot, profiles: model.profiles, rules: model.rules,
            settings: settings, sessionActive: sessionActive, now: Date())
        model.setAutomationPaused(policy.isPaused)

        switch decision {
        case .apply(let profileID, let trigger, let ruleID):
            let name = model.profile(id: profileID)?.name ?? "layout"
            Log.notice(.automation, "Rule matched (\(reason.rawValue)): applying “\(name)”",
                       details: ruleID.map { "rule \($0.uuidString)" })
            model.apply(profileID: profileID, origin: .automatic(trigger))
        case .skip(let skip):
            switch skip {
            case .noTopologyChange, .selfInduced:
                Log.debug(.automation, "No action (\(reason.rawValue)): \(skip)")
            case .circuitBreakerTripped:
                Log.warning(.automation, "Automation paused: \(skip)")
            default:
                Log.info(.automation, "No action (\(reason.rawValue)): \(skip)")
            }
        }
    }

    /// Samples the display topology until two consecutive samples match. A new external display
    /// without a port transport yet gets a short grace period. Returns false on timeout.
    private func waitForStableTopology(maxWait: Double) async throws -> Bool {
        guard let model else { return false }
        let start = Date()
        var previous = model.snapshots.captureTopology().signature
        var portGraceStart: Date?
        while Date().timeIntervalSince(start) < maxWait {
            try await Task.sleep(for: .seconds(Self.sampleIntervalSeconds))
            let sample = model.snapshots.captureTopology()
            defer { previous = sample.signature }
            guard sample.signature == previous else {
                portGraceStart = nil
                continue
            }
            let waitingForPort = sample.topologyStatus == .available && sample.externalDisplays.contains {
                $0.connection == .unidentified(.noTransport)
            }
            guard waitingForPort else { return true }
            let graceStart = portGraceStart ?? Date()
            portGraceStart = graceStart
            if Date().timeIntervalSince(graceStart) >= Self.portGraceSeconds { return true }
        }
        return false
    }
}

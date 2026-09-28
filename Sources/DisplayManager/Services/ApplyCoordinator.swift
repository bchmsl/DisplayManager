import DisplayManagerCore
import Foundation

/// Where an apply request came from.
enum ApplyOrigin: Hashable, Sendable {
    case menu
    case shortcut
    case manager
    case automatic(AutomationTrigger)

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .menu: "menu"
        case .shortcut: "keyboard shortcut"
        case .manager: "Layout Manager"
        case .automatic(.launch): "automatic (app launch)"
        case .automatic(.displayConnect): "automatic (display connected)"
        case .automatic(.wake): "automatic (wake)"
        }
    }
}

/// Runs one apply at a time. A newer request replaces a queued one; a running displayplacer process
/// is never killed (only the waits between attempts can be cancelled).
@MainActor
final class ApplyCoordinator {
    struct Request: Sendable {
        let profile: LayoutProfile
        let origin: ApplyOrigin
    }

    var willStart: ((Request) -> Void)?
    var didFinish: ((Request, ApplyReport) -> Void)?

    private let applier: LayoutApplier
    private var running: (request: Request, task: Task<Void, Never>)?
    private var queued: Request?

    init(control: any DisplayControl) {
        applier = LayoutApplier(control: control)
    }

    var isRunning: Bool { running != nil }
    var runningProfileID: UUID? { running?.request.profile.id }

    func submit(_ request: Request) {
        if running != nil {
            if let queued {
                Log.info(.apply, "Queued apply of “\(queued.profile.name)” replaced by “\(request.profile.name)”")
            }
            queued = request
            return
        }
        start(request)
    }

    /// Drops queued automatic work and stops a running automatic apply between attempts (before sleep).
    func cancelAutomatic() {
        if queued?.origin.isAutomatic == true { queued = nil }
        if let running, running.request.origin.isAutomatic { running.task.cancel() }
    }

    private func start(_ request: Request) {
        willStart?(request)
        let applier = applier
        let policy: ApplyPolicy = request.origin.isAutomatic ? .automatic : .manual
        let name = request.profile.name
        Log.notice(.apply, "Applying “\(name)” (\(request.origin.label))")
        let task = Task { [weak self] in
            let report = await applier.apply(profile: request.profile, policy: policy) { record in
                Log.info(.apply, "“\(name)” attempt \(record.attempt)/\(record.maxAttempts): \(record.summary)")
            }
            self?.finish(request, report)
        }
        running = (request, task)
    }

    private func finish(_ request: Request, _ report: ApplyReport) {
        running = nil
        switch report.result {
        case .applied(let attempts):
            Log.notice(.apply, "Applied “\(request.profile.name)” in \(counted(attempts, "attempt"))")
        case .alreadyApplied:
            Log.info(.apply, "“\(request.profile.name)” was already active")
        case .failed(let failure, let attempts):
            Log.error(.apply, "Applying “\(request.profile.name)” failed after \(counted(attempts, "attempt")): \(failure.message)",
                      details: failure.details)
        }
        didFinish?(request, report)
        if let next = queued {
            queued = nil
            start(next)
        }
    }
}

import AppKit
import DisplayManagerCore
import Foundation
import Observation

/// The result of the last apply of a profile, shown in the menu and the Layout Manager.
struct ApplyStatusRecord: Identifiable, Sendable {
    let id = UUID()
    let profileID: UUID
    let profileName: String
    let origin: ApplyOrigin
    let date: Date
    let result: ApplyResult
    let attempts: [ApplyAttemptRecord]

    var failure: ApplyFailure? { result.failure }
    var succeeded: Bool { failure == nil }

    var summary: String {
        switch result {
        case .applied: "Applied"
        case .alreadyApplied: "Already active"
        case .failed(let failure, _): failure.message
        }
    }

    /// Everything needed to understand a failure: message, details and every attempt with its output.
    var detailsText: String {
        var lines = ["Layout: \(profileName)", "Started by: \(origin.label)", "Time: \(date.formatted(date: .abbreviated, time: .standard))"]
        if let failure {
            lines.append("Result: \(failure.message)")
            if !failure.details.isEmpty { lines += ["", failure.details] }
        } else {
            lines.append("Result: \(summary)")
        }
        if !attempts.isEmpty {
            lines += ["", "Attempts:"]
            for attempt in attempts {
                lines.append("  \(attempt.attempt)/\(attempt.maxAttempts): \(attempt.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// What the menu shows as "Current Layout".
enum CurrentLayoutState: Equatable {
    case checking
    case displayplacerMissing
    case unknown
    case custom
    case profile(name: String)
    case applying(name: String)

    var menuTitle: String {
        switch self {
        case .checking: "Current Layout: Checking…"
        case .displayplacerMissing: "displayplacer not found"
        case .unknown: "Current Layout: Unknown"
        case .custom: "Current Layout: Custom"
        case .profile(let name): "Current Layout: \(name)"
        case .applying(let name): "Applying \(name)…"
        }
    }
}

/// The single UI state of the app. Every mutation that changes saved data persists immediately.
@MainActor @Observable
final class AppModel {
    // MARK: Services

    @ObservationIgnored let preferences: Preferences
    @ObservationIgnored let store: ProfileStore
    @ObservationIgnored let displayplacer = DisplayplacerClient()
    @ObservationIgnored let snapshots: SnapshotService
    @ObservationIgnored let hotKeys = HotKeyCenter()
    @ObservationIgnored let applyCoordinator: ApplyCoordinator
    @ObservationIgnored private(set) var automation: AutomationCoordinator?

    /// Presentation hooks, set by the app delegate.
    @ObservationIgnored var onManualApplyFailure: ((ApplyStatusRecord) -> Void)?
    @ObservationIgnored var onPersistenceError: ((DisplayManagerError) -> Void)?

    // MARK: State

    private(set) var document = LayoutDocument()
    private(set) var snapshot: SystemSnapshot?
    private(set) var snapshotError: DisplayManagerError?
    private(set) var currentProfileID: UUID?
    private(set) var displayplacerStatus = DisplayplacerStatus()
    private(set) var hasCheckedDisplays = false

    private(set) var autoApplyEnabled: Bool
    private(set) var reapplyAfterWake: Bool
    private(set) var settleDelaySeconds: Double
    private(set) var displayplacerPathOverride: String?
    private(set) var loginItemStatus: LoginItemController.Status

    private(set) var applyingProfileID: UUID?
    private(set) var lastResults: [UUID: ApplyStatusRecord] = [:]
    private(set) var recentApplies: [ApplyStatusRecord] = []
    /// The latest failure the user has not looked at yet.
    private(set) var pendingFailure: ApplyStatusRecord?
    private(set) var automationPaused = false
    private(set) var shortcutProblems: [UUID: ShortcutProblem] = [:]
    private(set) var persistenceError: DisplayManagerError?

    @ObservationIgnored private(set) var startupLoadResult: ProfileStore.LoadResult = .missing
    @ObservationIgnored private var lastManualRequest: (profileID: UUID, date: Date)?
    @ObservationIgnored private var lastLoggedSignature: TopologySignature?

    init(preferences: Preferences = Preferences(), store: ProfileStore = ProfileStore()) {
        self.preferences = preferences
        self.store = store
        let snapshots = SnapshotService(displayplacer: displayplacer)
        self.snapshots = snapshots
        self.applyCoordinator = ApplyCoordinator(control: snapshots)
        autoApplyEnabled = preferences.autoApplyEnabled
        reapplyAfterWake = preferences.reapplyAfterWake
        settleDelaySeconds = preferences.settleDelaySeconds
        displayplacerPathOverride = preferences.displayplacerPathOverride
        loginItemStatus = LoginItemController.status

        startupLoadResult = store.load()
        if case .loaded(let loaded) = startupLoadResult { document = loaded }

        applyCoordinator.willStart = { [weak self] request in self?.applyWillStart(request) }
        applyCoordinator.didFinish = { [weak self] request, report in self?.applyDidFinish(request, report) }
        hotKeys.onHotKey = { [weak self] profileID in self?.apply(profileID: profileID, origin: .shortcut) }
        automation = AutomationCoordinator(model: self)
    }

    /// Starts discovery, the first snapshot, hotkeys and automation.
    func start() async {
        hotKeys.install()
        syncHotKeys()
        await refreshDisplayplacer()
        await refreshSnapshot()
        automation?.start()
    }

    // MARK: Derived state

    var profiles: [LayoutProfile] { document.profiles }
    var rules: [AutoApplyRule] { document.rules }
    var knownPorts: [KnownPort] { document.knownPorts }

    func profile(id: UUID) -> LayoutProfile? { document.profiles.first { $0.id == id } }

    /// The UI edits one rule per profile.
    func rule(for profileID: UUID) -> AutoApplyRule? { document.rules.first { $0.profileID == profileID } }

    var currentLayoutState: CurrentLayoutState {
        if let applyingProfileID, let profile = profile(id: applyingProfileID) { return .applying(name: profile.name) }
        if displayplacerStatus.state == .notChecked || !hasCheckedDisplays { return .checking }
        if !displayplacerStatus.isUsable { return .displayplacerMissing }
        guard let snapshot, snapshot.configuration != nil else { return .unknown }
        if let currentProfileID, let profile = profile(id: currentProfileID) { return .profile(name: profile.name) }
        return .custom
    }

    /// Nil when the profile can be applied now, otherwise the reason (for tooltips and disabled buttons).
    func unavailableReason(for profile: LayoutProfile) -> String? {
        guard displayplacerStatus.isUsable else { return displayplacerStatus.summary }
        guard let snapshot else { return "The connected displays are not known yet." }
        let resolution = DisplayResolver.resolve(profile: profile, snapshot: snapshot)
        let missing = profile.enabledDisplayIDs.filter { resolution.liveID(forSaved: $0) == nil }
        guard !missing.isEmpty else { return nil }
        var seen = Set<String>()
        let names = missing.map { profile.displayInfo(for: $0).name }.filter { seen.insert($0).inserted }
        return "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") not connected."
    }

    /// Icon badge: an automatic apply failed and the user has not opened the details.
    var showsFailureBadge: Bool { pendingFailure?.origin.isAutomatic == true }

    func portLabel(for connection: ConnectionState) -> String {
        switch connection {
        case .builtIn: "Built-in"
        case .external(let fingerprint): document.knownPorts.label(for: fingerprint)
        case .unidentified(let reason): Self.shortReason(reason)
        }
    }

    static func shortReason(_ reason: UnidentifiedReason) -> String {
        switch reason {
        case .noTransport: "Port unknown"
        case .ambiguous: "Port ambiguous"
        case .noPortInfo: "Port not reported"
        case .topologyUnavailable: "Port detection not available"
        }
    }

    // MARK: Refresh

    func refreshDisplayplacer() async {
        displayplacerStatus = await displayplacer.refresh(override: displayplacerPathOverride)
    }

    /// Captures a fresh snapshot (best effort) and updates the current layout.
    @discardableResult
    func refreshSnapshot() async -> SystemSnapshot {
        let (fresh, error) = await snapshots.captureBestEffort()
        update(snapshot: fresh, error: error)
        return fresh
    }

    /// A full snapshot for saving. Throws when displayplacer cannot report the configuration.
    func captureForSave() async throws -> SystemSnapshot {
        if !displayplacerStatus.isUsable { await refreshDisplayplacer() }
        do {
            let fresh = try await snapshots.captureSnapshot()
            update(snapshot: fresh, error: nil)
            return fresh
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .malformedListOutput(detail: error.localizedDescription)
            await refreshSnapshot()
            throw managerError
        }
    }

    private func update(snapshot fresh: SystemSnapshot, error: DisplayManagerError?) {
        snapshot = fresh
        snapshotError = error
        hasCheckedDisplays = true
        if let error, displayplacerStatus.isUsable {
            Log.warning(.displayplacer, error.userMessage, details: error.diagnosticDetail)
        }
        if fresh.signature != lastLoggedSignature {
            lastLoggedSignature = fresh.signature
            let summary = fresh.displays.map { "\($0.name) [\(portLabel(for: $0.connection))]" }.joined(separator: ", ")
            Log.info(.displays, "\(counted(fresh.displays.count, "display")) connected: \(summary)",
                     details: fresh.displays.map { "\($0.persistentID) \($0.connection.signatureKey) \($0.transportDescription ?? "")" }.joined(separator: "; "))
        }
        recomputeCurrentProfile()
    }

    private func recomputeCurrentProfile() {
        guard let snapshot, snapshot.configuration != nil else {
            currentProfileID = nil
            return
        }
        currentProfileID = LayoutComparator.currentProfile(in: document.profiles, snapshot: snapshot)?.id
    }

    func refreshLoginItemStatus() {
        let status = LoginItemController.status
        if status != loginItemStatus { loginItemStatus = status }
    }

    // MARK: Apply

    func apply(profileID: UUID, origin: ApplyOrigin) {
        guard let profile = profile(id: profileID) else { return }
        if !origin.isAutomatic {
            // The same shortcut can arrive from the menu key equivalent and the Carbon hotkey.
            if let last = lastManualRequest, last.profileID == profileID, Date().timeIntervalSince(last.date) < 1 {
                Log.debug(.apply, "Ignored duplicate apply request for “\(profile.name)”")
                return
            }
            lastManualRequest = (profileID, Date())
        }
        applyCoordinator.submit(ApplyCoordinator.Request(profile: profile, origin: origin))
    }

    private func applyWillStart(_ request: ApplyCoordinator.Request) {
        applyingProfileID = request.profile.id
        automation?.applyDidStart()
    }

    private func applyDidFinish(_ request: ApplyCoordinator.Request, _ report: ApplyReport) {
        applyingProfileID = nil
        automation?.applyDidFinish(signature: report.finalSnapshot?.signature)
        if let final = report.finalSnapshot {
            update(snapshot: final, error: nil)
        }

        let record = ApplyStatusRecord(
            profileID: request.profile.id, profileName: request.profile.name, origin: request.origin,
            date: Date(), result: report.result, attempts: report.attempts)
        lastResults[request.profile.id] = record
        recentApplies.append(record)
        if recentApplies.count > 10 { recentApplies.removeFirst(recentApplies.count - 10) }

        if record.succeeded {
            pendingFailure = nil
        } else if request.origin.isAutomatic {
            pendingFailure = record
        } else {
            pendingFailure = nil
            onManualApplyFailure?(record)
        }
        if report.finalSnapshot == nil {
            Task { await refreshSnapshot() }
        }
    }

    /// The user opened the failure details.
    func acknowledgeFailure() {
        pendingFailure = nil
    }

    func setAutomationPaused(_ paused: Bool) {
        if automationPaused != paused { automationPaused = paused }
    }

    // MARK: Preferences

    func setAutoApplyEnabled(_ enabled: Bool) {
        autoApplyEnabled = enabled
        preferences.autoApplyEnabled = enabled
        if enabled { automation?.resume() }
        Log.info(.automation, "Auto Apply \(enabled ? "on" : "off")")
    }

    func setReapplyAfterWake(_ enabled: Bool) {
        reapplyAfterWake = enabled
        preferences.reapplyAfterWake = enabled
        Log.info(.automation, "Reapply After Wake \(enabled ? "on" : "off")")
    }

    func setSettleDelaySeconds(_ seconds: Double) {
        preferences.settleDelaySeconds = seconds
        settleDelaySeconds = preferences.settleDelaySeconds
    }

    func setDisplayplacerPathOverride(_ path: String?) async {
        preferences.displayplacerPathOverride = path
        displayplacerPathOverride = preferences.displayplacerPathOverride
        await refreshDisplayplacer()
        await refreshSnapshot()
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { refreshLoginItemStatus() }
        try LoginItemController.setEnabled(enabled)
    }

    // MARK: Profiles

    func suggestedProfileName() -> String {
        let used = Set(document.profiles.map { $0.name.lowercased() })
        var index = document.profiles.count + 1
        while used.contains("layout \(index)") { index += 1 }
        return "Layout \(index)"
    }

    func profile(named name: String) -> LayoutProfile? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return document.profiles.first { $0.name.lowercased() == key }
    }

    /// Saves the current layout as a new profile or replaces the screens of an existing one.
    ///
    /// Replacing keeps the id, the rule and the shortcut. `createRule` adds a rule with the currently
    /// identified ports (or replaces the existing rule's requirements).
    @discardableResult
    func saveProfile(name: String, from snapshot: SystemSnapshot, replacing existingID: UUID?, createRule: Bool) -> LayoutProfile? {
        guard let configuration = snapshot.configuration else { return nil }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ImportValidator.maximumNameLength))
        let mentioned = Set(configuration.flatMap(\.displayIDs).map { $0.lowercased() })
        let displays = snapshot.displays.filter { mentioned.contains($0.persistentID.lowercased()) }.map(\.displayInfo)
        let now = Date()

        var profile: LayoutProfile
        if let existingID, let index = document.profiles.firstIndex(where: { $0.id == existingID }) {
            profile = document.profiles[index]
            profile.name = trimmed
            profile.screens = configuration
            profile.displays = displays
            profile.sourceCommand = snapshot.parsedList?.commandLine
            profile.updatedAt = now
            document.profiles[index] = profile
            Log.notice(.persistence, "Replaced layout “\(trimmed)”")
        } else {
            profile = LayoutProfile(
                name: trimmed, createdAt: now, updatedAt: now, screens: configuration, displays: displays,
                sourceCommand: snapshot.parsedList?.commandLine)
            document.profiles.append(profile)
            Log.notice(.persistence, "Saved layout “\(trimmed)”")
        }

        if createRule {
            var rule = rule(for: profile.id) ?? AutoApplyRule(profileID: profile.id)
            rule.isEnabled = true
            rule.connectionRequirements = snapshot.externalDisplays.compactMap { live in
                guard mentioned.contains(live.persistentID.lowercased()), let fingerprint = live.connection.fingerprint else { return nil }
                return ConnectionRequirement(persistentID: live.persistentID, connection: fingerprint)
            }
            rule.connectionRequirements.forEach { registerKnownPort($0.connection) }
            upsertRule(rule)
        }
        persist()
        recomputeCurrentProfile()
        return profile
    }

    enum RenameProblem: Error, Equatable {
        case empty
        case tooLong
        case taken
    }

    func renameProblem(_ name: String, for profileID: UUID) -> RenameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > ImportValidator.maximumNameLength { return .tooLong }
        if let other = profile(named: trimmed), other.id != profileID { return .taken }
        return nil
    }

    func rename(profileID: UUID, to name: String) throws(RenameProblem) {
        if let problem = renameProblem(name, for: profileID) { throw problem }
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document.profiles[index].name != trimmed else { return }
        document.profiles[index].name = trimmed
        document.profiles[index].updatedAt = Date()
        persist()
    }

    /// Copies the screens and displays. The shortcut and the rule are not copied (they would conflict).
    @discardableResult
    func duplicate(profileID: UUID) -> LayoutProfile? {
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        let original = document.profiles[index]
        let used = Set(document.profiles.map { $0.name.lowercased() })
        let now = Date()
        let copy = LayoutProfile(
            name: ImportValidator.uniqueName(for: "\(original.name) Copy", used: used),
            createdAt: now, updatedAt: now, screens: original.screens, displays: original.displays,
            sourceCommand: original.sourceCommand)
        document.profiles.insert(copy, at: index + 1)
        persist()
        recomputeCurrentProfile()
        return copy
    }

    /// Deletes the profile, its rules and its shortcut.
    func delete(profileID: UUID) {
        guard let profile = profile(id: profileID) else { return }
        document.profiles.removeAll { $0.id == profileID }
        document.rules.removeAll { $0.profileID == profileID }
        lastResults[profileID] = nil
        shortcutProblems[profileID] = nil
        if pendingFailure?.profileID == profileID { pendingFailure = nil }
        persist()
        syncHotKeys()
        recomputeCurrentProfile()
        Log.notice(.persistence, "Deleted layout “\(profile.name)”")
    }

    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        document.profiles.move(fromOffsets: source, toOffset: destination)
        persist()
        recomputeCurrentProfile()
    }

    /// Replaces the screens with the current layout (Advanced › Update From Current Layout…).
    func updateFromCurrentLayout(profileID: UUID) async throws {
        guard let profile = profile(id: profileID) else { return }
        let fresh = try await captureForSave()
        saveProfile(name: profile.name, from: fresh, replacing: profileID, createRule: false)
    }

    // MARK: Rules and ports

    func upsertRule(_ rule: AutoApplyRule) {
        document.rules.removeAll { $0.profileID == rule.profileID && $0.id != rule.id }
        if let index = document.rules.firstIndex(where: { $0.id == rule.id }) {
            document.rules[index] = rule
        } else {
            document.rules.append(rule)
        }
    }

    func setRule(_ rule: AutoApplyRule?, for profileID: UUID) {
        if let rule {
            upsertRule(rule)
            rule.connectionRequirements.forEach { registerKnownPort($0.connection) }
        } else {
            document.rules.removeAll { $0.profileID == profileID }
        }
        persist()
    }

    func conflictingRules(for rule: AutoApplyRule) -> [AutoApplyRule] {
        var rules = document.rules.filter { $0.id != rule.id && $0.profileID != rule.profileID }
        rules.append(rule)
        return RuleMatcher.conflictingRules(for: rule, rules: rules, profiles: document.profiles)
    }

    func registerKnownPort(_ connection: ConnectionFingerprint) {
        guard !document.knownPorts.contains(where: { $0.connection == connection }) else { return }
        document.knownPorts.append(KnownPort(connection: connection, name: ""))
    }

    func renameKnownPort(_ connection: ConnectionFingerprint, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if let index = document.knownPorts.firstIndex(where: { $0.connection == connection }) {
            guard document.knownPorts[index].name != trimmed else { return }
            document.knownPorts[index].name = trimmed
        } else {
            document.knownPorts.append(KnownPort(connection: connection, name: trimmed))
        }
        persist()
    }

    /// Removes a learned port name. Rules that require the port keep working.
    func deleteKnownPort(_ connection: ConnectionFingerprint) {
        document.knownPorts.removeAll { $0.connection == connection }
        persist()
    }

    enum LearnPortError: Error, Equatable {
        case displayplacerNeeded
        case notConnected(name: String)
        case unidentified(name: String, reason: UnidentifiedReason)

        var message: String {
            switch self {
            case .displayplacerNeeded: "The connected displays could not be read."
            case .notConnected(let name): "Connect \(name) to the port you want, then try again."
            case .unidentified(let name, let reason): "\(name): \(reason.userMessage)"
            }
        }
    }

    /// Reads the port the display of a profile is connected to right now.
    func learnCurrentPort(profileID: UUID, persistentID: String) async -> Result<ConnectionFingerprint, LearnPortError> {
        guard let profile = profile(id: profileID) else { return .failure(.displayplacerNeeded) }
        let name = profile.displayInfo(for: persistentID).name
        let fresh = await refreshSnapshot()
        let resolution = DisplayResolver.resolve(profile: profile, snapshot: fresh)
        guard let liveID = resolution.liveID(forSaved: persistentID), let live = fresh.display(persistentID: liveID) else {
            return .failure(.notConnected(name: name))
        }
        switch live.connection {
        case .external(let fingerprint):
            Log.notice(.topology, "Learned port for \(name): \(fingerprint.technicalLabel)")
            return .success(fingerprint)
        case .unidentified(let reason):
            return .failure(.unidentified(name: name, reason: reason))
        case .builtIn:
            return .failure(.unidentified(name: name, reason: .noPortInfo))
        }
    }

    // MARK: Shortcuts

    /// Validates and stores a shortcut. Call while the recorder has the hotkeys suspended.
    func setShortcut(_ shortcut: KeyShortcut?, for profileID: UUID) -> ShortcutProblem? {
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else { return nil }
        if let shortcut {
            if let problem = ShortcutValidator.validate(shortcut, for: profileID, profiles: document.profiles) { return problem }
            if let problem = hotKeys.availabilityProblem(for: shortcut) { return problem }
        }
        document.profiles[index].shortcut = shortcut
        document.profiles[index].updatedAt = Date()
        persist()
        syncHotKeys()
        return nil
    }

    func syncHotKeys() {
        let shortcuts = document.profiles.compactMap { profile in profile.shortcut.map { (profileID: profile.id, shortcut: $0) } }
        let problems = hotKeys.update(shortcuts)
        if !hotKeys.isSuspended { shortcutProblems = problems }
    }

    /// Unregisters all hotkeys while the recorder captures keys.
    func beginShortcutRecording() {
        hotKeys.suspend()
    }

    func endShortcutRecording() {
        guard hotKeys.isSuspended else { return }
        hotKeys.resume()
        syncHotKeys()
    }

    // MARK: Import and export

    /// The whole document, or the given profiles with their rules and the ports those rules use.
    func exportDocument(profileIDs: Set<UUID>? = nil) -> LayoutDocument {
        guard let profileIDs else { return document }
        let profiles = document.profiles.filter { profileIDs.contains($0.id) }
        let rules = document.rules.filter { profileIDs.contains($0.profileID) }
        let portKeys = Set(rules.flatMap(\.connectionRequirements).map(\.connection.key)
            + profiles.flatMap(\.displays).compactMap(\.connection?.key))
        let ports = document.knownPorts.filter { portKeys.contains($0.connection.key) }
        return LayoutDocument(profiles: profiles, rules: rules, knownPorts: ports)
    }

    func export(profileIDs: Set<UUID>?, to url: URL) throws {
        let exported = exportDocument(profileIDs: profileIDs)
        try store.export(exported, to: url)
        Log.notice(.persistence, "Exported \(counted(exported.profiles.count, "layout"))")
    }

    /// Applies a validated import. "Replace All" makes a backup first and refuses to continue without one.
    func applyImport(_ imported: LayoutDocument, mode: ImportMode) throws -> ImportSummary {
        if mode == .replaceAll {
            try store.save(document)
            try store.backup()
        }
        let (merged, summary) = ImportValidator.merge(imported, into: document, mode: mode)
        document = merged
        persist()
        syncHotKeys()
        recomputeCurrentProfile()
        Log.notice(.persistence, "Imported \(counted(summary.addedProfiles, "layout")) and \(counted(summary.addedRules, "rule")) (\(mode == .add ? "add" : "replace all"))")
        return summary
    }

    // MARK: Persistence

    private func persist() {
        do {
            try store.save(document)
            persistenceError = nil
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .persistenceFailed(error.localizedDescription)
            // Alert once per failure streak; the in-memory state is kept and saved again on the next change.
            if persistenceError == nil { onPersistenceError?(managerError) }
            persistenceError = managerError
        }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        var lines: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("DisplayManager \(AppInfo.version) (\(AppInfo.build))")
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Mac model: \(snapshots.hostModel)")
        lines.append("App location: \(Bundle.main.bundlePath)")
        lines.append("")
        lines.append("displayplacer: \(displayplacerStatus.summary)")
        lines.append("  path: \(displayplacerStatus.path ?? "none")\(displayplacerStatus.resolvedPath.map { " -> \($0)" } ?? "")")
        if displayplacerStatus.overrideIsInvalid { lines.append("  custom path is not an executable file") }
        lines.append("")
        lines.append("Auto Apply: \(autoApplyEnabled ? "on" : "off"), Reapply After Wake: \(reapplyAfterWake ? "on" : "off"), wait after wake: \(settleDelaySeconds) s")
        lines.append("Automation paused: \(automationPaused ? "yes" : "no")")
        lines.append("Current layout: \(currentLayoutState.menuTitle)")
        lines.append("Layouts: \(profiles.count), rules: \(rules.count), learned ports: \(knownPorts.count)")
        lines.append("")
        if let snapshot {
            lines.append("Displays (captured \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))):")
            if case .unavailable(let reason) = snapshot.topologyStatus { lines.append("  Port detection: not available (\(reason))") }
            for display in snapshot.displays {
                var parts = ["  • \(display.name)", display.isBuiltIn ? "built-in" : "external"]
                if display.isMain { parts.append("main") }
                if !display.isEnabled { parts.append("disabled") }
                parts.append("port: \(portLabel(for: display.connection))")
                if let transport = display.transportDescription { parts.append("transport: \(transport)") }
                if let bounds = display.bounds { parts.append("bounds: \(bounds.x),\(bounds.y) \(bounds.width)x\(bounds.height)") }
                lines.append(parts.joined(separator: " | "))
                lines.append("    id: \(display.persistentID), vendor: \(display.vendorID.map(String.init) ?? "?"), product: \(display.productID.map(String.init) ?? "?"), serial: \(display.serialNumber.map(String.init) ?? "?")")
            }
            if let command = snapshot.parsedList?.commandLine {
                lines += ["", "Current command:", command]
            }
        } else {
            lines.append("Displays: not captured yet")
        }
        if let snapshotError {
            lines += ["", "Last snapshot error: \(snapshotError.userMessage)"]
            if let detail = snapshotError.diagnosticDetail { lines.append(detail) }
        }
        if !recentApplies.isEmpty {
            lines += ["", "Recent applies:"]
            for record in recentApplies.suffix(5) {
                lines.append("")
                lines.append(record.detailsText)
                for attempt in record.attempts {
                    guard let output = attempt.output else { continue }
                    lines.append("  attempt \(attempt.attempt) exit \(output.exitCode), \(String(format: "%.2f", output.duration)) s\(output.timedOut ? ", timed out" : "")")
                    if !output.combinedOutput.isEmpty { lines.append("  output: \(output.combinedOutput)") }
                }
            }
        }
        let events = DiagnosticsLog.shared.entries.suffix(80)
        if !events.isEmpty {
            lines += ["", "Recent events:"]
            for entry in events {
                var line = "\(entry.date.formatted(date: .omitted, time: .standard)) [\(entry.category.rawValue)] \(entry.level.rawValue): \(entry.message)"
                if let details = entry.details, !details.isEmpty { line += " | \(details)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

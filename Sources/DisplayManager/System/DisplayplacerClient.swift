import DisplayManagerCore
import Foundation

/// What the app knows about the displayplacer executable.
struct DisplayplacerStatus: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case notChecked
        case ready
        /// Runs, but `--version` output was not recognized. Still used; parsing errors are reported if the format differs.
        case versionUnknown
        case unsupportedVersion
        case notFound
        case notRunnable(String)
    }

    var state: State = .notChecked
    var path: String?
    /// Symlink target, for display (Homebrew links into its Cellar).
    var resolvedPath: String?
    var source: ExecutableLocator.Source?
    var version: DisplayplacerVersion?
    var overrideIsInvalid = false

    var isUsable: Bool { state == .ready || state == .versionUnknown }

    /// One line for the menu and Settings.
    var summary: String {
        switch state {
        case .notChecked: "Checking displayplacer…"
        case .ready: "displayplacer \(version?.description ?? "") is installed"
        case .versionUnknown: "displayplacer is installed (version not recognized)"
        case .unsupportedVersion: "displayplacer \(version?.description ?? "") is too old (1.4.0 or newer is needed)"
        case .notFound: "displayplacer not found"
        case .notRunnable(let reason): "displayplacer could not be started: \(reason)"
        }
    }

    /// The error to report when an action needs displayplacer and it is not usable.
    var unavailableError: DisplayManagerError {
        switch state {
        case .unsupportedVersion: .unsupportedDisplayplacerVersion(found: version?.description ?? "unknown")
        case .notRunnable(let reason): .executableUnavailable(path: path ?? "displayplacer", reason: reason)
        default: .displayplacerNotFound
        }
    }
}

/// Finds and runs displayplacer. Never installs anything and never runs a login shell.
actor DisplayplacerClient {
    static let versionTimeout: TimeInterval = 5
    static let commandTimeout: TimeInterval = 20

    private(set) var status = DisplayplacerStatus()
    private var pathOverride: String?

    /// Locates the executable and checks its version.
    @discardableResult
    func refresh(override: String?) async -> DisplayplacerStatus {
        pathOverride = override
        let result = ExecutableLocator.locate(
            override: override,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            homeDirectory: NSHomeDirectory(),
            isExecutable: Self.isExecutableFile
        )
        var next = DisplayplacerStatus(overrideIsInvalid: result.overrideIsInvalid)
        guard let path = result.path else {
            next.state = .notFound
            // Log changes only; Settings re-checks every time it opens.
            if next != status { Log.warning(.displayplacer, "displayplacer not found") }
            status = next
            return next
        }
        next.path = path
        next.source = result.source
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        next.resolvedPath = resolved == path ? nil : resolved

        do {
            let output = try await ProcessRunner.run(executable: path, arguments: ["--version"], timeout: Self.versionTimeout)
            if let version = DisplayplacerVersion.parse(output.stdout + "\n" + output.stderr) {
                next.version = version
                next.state = version.isSupported ? .ready : .unsupportedVersion
            } else {
                next.state = .versionUnknown
            }
        } catch let error as DisplayManagerError {
            next.state = .notRunnable(error.diagnosticDetail ?? error.userMessage)
        } catch {
            next.state = .notRunnable(error.localizedDescription)
        }
        if next != status {
            if next.isUsable {
                Log.info(.displayplacer, next.summary, details: path)
            } else {
                Log.warning(.displayplacer, next.summary, details: path)
            }
        }
        status = next
        return next
    }

    /// Runs `displayplacer list` and parses it.
    func list() async throws -> ParsedList {
        let path = try await usablePath()
        let output = try await ProcessRunner.run(executable: path, arguments: ["list"], timeout: Self.commandTimeout)
        if output.timedOut { throw DisplayManagerError.processTimedOut(seconds: Int(Self.commandTimeout)) }
        guard output.exitCode == 0 else {
            throw DisplayManagerError.malformedListOutput(
                detail: "displayplacer list exited with code \(output.exitCode).\n\(output.combinedOutput)")
        }
        return try ListOutputParser.parse(output.stdout)
    }

    /// Runs displayplacer with one argument per screen spec.
    func run(arguments: [String]) async throws -> ProcessOutput {
        let path = try await usablePath()
        return try await ProcessRunner.run(executable: path, arguments: arguments, timeout: Self.commandTimeout)
    }

    var executablePath: String? { status.path }

    /// The cached path, re-discovered when it is missing or vanished.
    private func usablePath() async throws -> String {
        if status.state == .notChecked || (status.path.map { !Self.isExecutableFile($0) } ?? false) {
            await refresh(override: pathOverride)
        }
        guard status.isUsable, let path = status.path else { throw status.unavailableError }
        return path
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

import Foundation

/// Result of running a subprocess.
public struct ProcessOutput: Hashable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var duration: TimeInterval
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, duration: TimeInterval, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
        self.timedOut = timedOut
    }

    public var combinedOutput: String {
        [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Classification of a displayplacer apply run. Exit code and later verification are the ground truth;
/// the output text only refines the message.
public enum RunOutcome: Hashable, Sendable {
    case success
    case displayNotFound
    case unsupportedMode
    case invalidArguments
    case timedOut
    case failed(exitCode: Int32)

    public static func classify(_ output: ProcessOutput) -> RunOutcome {
        if output.timedOut { return .timedOut }
        if output.exitCode == 0 { return .success }
        let text = output.combinedOutput.lowercased()
        if text.contains("unable to find screen") { return .displayNotFound }
        if text.contains("argument parsing error") { return .invalidArguments }
        let modeHints = ["could not find res", "could not find mode", "no matching mode", "not supported", "unsupported"]
        if modeHints.contains(where: text.contains) { return .unsupportedMode }
        return .failed(exitCode: output.exitCode)
    }
}

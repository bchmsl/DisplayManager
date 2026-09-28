import DisplayManagerCore
import Foundation

/// Runs a subprocess without a shell. stdout and stderr are drained concurrently (no pipe deadlock).
/// On timeout the process gets SIGTERM, then SIGKILL after 2 seconds.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: {
                    try runBlocking(executable: executable, arguments: arguments, timeout: timeout)
                }))
            }
        }
    }

    private static func runBlocking(executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // A predictable, minimal environment: no user shell configuration is involved.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let start = Date()
        do {
            try process.run()
        } catch {
            throw DisplayManagerError.executableUnavailable(path: executable, reason: error.localizedDescription)
        }

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let readers = DispatchGroup()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            stdoutBuffer.store((try? stdoutHandle.readToEnd()) ?? Data())
        }
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            stderrBuffer.store((try? stderrHandle.readToEnd()) ?? Data())
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // Readers finish when the pipes close. Bound the wait in case a child process keeps them open.
        _ = readers.wait(timeout: .now() + 2)

        return ProcessOutput(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(decoding: stdoutBuffer.data, as: UTF8.self),
            stderr: String(decoding: stderrBuffer.data, as: UTF8.self),
            duration: Date().timeIntervalSince(start),
            timedOut: timedOut
        )
    }
}

/// Collects pipe data written by a reader thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    func store(_ data: Data) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

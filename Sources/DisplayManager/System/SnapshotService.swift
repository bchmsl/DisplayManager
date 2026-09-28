import DisplayManagerCore
import Foundation

/// Builds one consistent view of the displays: CoreGraphics + IORegistry ports + displayplacer list.
@MainActor
final class SnapshotService: DisplayControl {
    let displayplacer: DisplayplacerClient
    let hostModel: String

    init(displayplacer: DisplayplacerClient) {
        self.displayplacer = displayplacer
        self.hostModel = PortTopologyReader.hostModel()
    }

    // MARK: DisplayControl

    /// Full snapshot. Throws when displayplacer is missing or its output cannot be read.
    func captureSnapshot() async throws -> SystemSnapshot {
        let parsed = try await displayplacer.list()
        return assemble(parsedList: parsed)
    }

    func runDisplayplacer(arguments: [String]) async throws -> ProcessOutput {
        try await displayplacer.run(arguments: arguments)
    }

    var executablePathForDisplay: String? {
        get async { await displayplacer.executablePath }
    }

    // MARK: Other captures

    /// Always returns a snapshot. Without displayplacer the displays and ports are still known,
    /// but the configuration is nil (Current Layout shows Unknown).
    func captureBestEffort() async -> (snapshot: SystemSnapshot, error: DisplayManagerError?) {
        do {
            return (try await captureSnapshot(), nil)
        } catch let error as DisplayManagerError {
            return (assemble(parsedList: nil), error)
        } catch {
            return (assemble(parsedList: nil), .malformedListOutput(detail: error.localizedDescription))
        }
    }

    /// Displays and ports only, without running displayplacer. Used for stability sampling.
    func captureTopology() -> SystemSnapshot {
        assemble(parsedList: nil)
    }

    private func assemble(parsedList: ParsedList?) -> SystemSnapshot {
        let topology = PortTopologyReader.read()
        return SnapshotAssembler.assemble(
            cgDisplays: CGDisplayReader.onlineDisplays(),
            transports: topology.records,
            topologyStatus: topology.status,
            parsedList: parsedList,
            hostModel: hostModel,
            capturedAt: Date()
        )
    }
}

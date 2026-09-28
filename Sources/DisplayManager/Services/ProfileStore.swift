import DisplayManagerCore
import Foundation

/// Reads and writes `layouts.json` in Application Support. Every write is atomic.
///
/// The existing file is never overwritten silently: an unreadable file is moved aside first, and
/// "Replace All" imports make a backup.
@MainActor
final class ProfileStore {
    enum LoadResult {
        /// No file yet (first launch).
        case missing
        case loaded(LayoutDocument)
        /// The file could not be read. It was moved to `movedTo` and the app starts empty.
        case recovered(error: DisplayManagerError, movedTo: URL?)
    }

    static let fileName = "layouts.json"
    static let backupsToKeep = 5

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("DisplayManager", isDirectory: true)
        }
    }

    func load() -> LoadResult {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            // Structural decoding only. Values are checked again when a command is built, so a saved
            // layout that fails a strict import rule is kept instead of being moved aside.
            let document = try LayoutDocument.decode(data)
            Log.info(.persistence, "Loaded \(document.profiles.count) layouts and \(document.rules.count) rules")
            return .loaded(document)
        } catch {
            let managerError = (error as? DisplayManagerError) ?? .persistenceFailed(error.localizedDescription)
            let movedTo = moveAside(url, prefix: "layouts.corrupt")
            Log.error(.persistence, "Layouts file could not be read and was moved aside",
                      details: [managerError.diagnosticDetail, movedTo?.lastPathComponent].compactMap { $0 }.joined(separator: " "))
            return .recovered(error: managerError, movedTo: movedTo)
        }
    }

    func save(_ document: LayoutDocument) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var stamped = document
            stamped.version = LayoutDocument.currentVersion
            stamped.exportedBy = "DisplayManager \(AppInfo.version)"
            try stamped.encoded().write(to: fileURL, options: .atomic)
        } catch {
            Log.error(.persistence, "Saving layouts failed", details: error.localizedDescription)
            throw DisplayManagerError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Copies the current file to `layouts.backup-<timestamp>.json` and keeps the newest five backups.
    @discardableResult
    func backup() throws -> URL? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let destination = directory.appendingPathComponent("layouts.backup-\(Self.timestamp()).json")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw DisplayManagerError.persistenceFailed("Backup failed: \(error.localizedDescription)")
        }
        pruneBackups()
        Log.info(.persistence, "Backup created", details: destination.lastPathComponent)
        return destination
    }

    /// Writes an export file. Uses the same format as `layouts.json`.
    func export(_ document: LayoutDocument, to url: URL) throws {
        var stamped = document
        stamped.version = LayoutDocument.currentVersion
        stamped.exportedBy = "DisplayManager \(AppInfo.version)"
        do {
            try stamped.encoded().write(to: url, options: .atomic)
        } catch {
            throw DisplayManagerError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Reads and validates an import file without changing anything.
    func readImport(from url: URL) throws -> LayoutDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= LayoutDocument.maximumImportSize else { throw DisplayManagerError.documentTooLarge(bytes: size) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DisplayManagerError.invalidDocument(error.localizedDescription)
        }
        guard data.count <= LayoutDocument.maximumImportSize else { throw DisplayManagerError.documentTooLarge(bytes: data.count) }
        let document = try LayoutDocument.decode(data)
        let issues = ImportValidator.validate(document)
        guard issues.isEmpty else {
            let listed = issues.prefix(10).map { "• \($0.description)" }.joined(separator: "\n")
            let more = issues.count > 10 ? "\n…and \(issues.count - 10) more." : ""
            throw DisplayManagerError.invalidDocument(listed + more)
        }
        return document
    }

    // MARK: Helpers

    private func moveAside(_ url: URL, prefix: String) -> URL? {
        let destination = directory.appendingPathComponent("\(prefix)-\(Self.timestamp()).json")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func pruneBackups() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        // Timestamps sort lexicographically in chronological order.
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("layouts.backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(Self.backupsToKeep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.bachana.DisplayManager" }

    static var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }
}

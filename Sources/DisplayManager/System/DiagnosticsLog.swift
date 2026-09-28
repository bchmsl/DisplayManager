import Foundation
import Observation
import os

enum LogCategory: String, CaseIterable, Sendable {
    case app, displays, topology, displayplacer, automation, apply, persistence, hotkeys, login
}

enum LogLevel: String, Sendable {
    case debug, info, notice, warning, error

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .fault
        }
    }
}

struct DiagnosticsEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let date: Date
    let category: LogCategory
    let level: LogLevel
    let message: String
    /// Identifiers and raw output. Private in the unified log, visible in the in-app list and copied diagnostics.
    let details: String?
}

/// Recent activity kept in memory for Settings › Automation and Copy Diagnostics.
@MainActor @Observable
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    static let capacity = 300

    private(set) var entries: [DiagnosticsEntry] = []

    fileprivate func append(_ entry: DiagnosticsEntry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func clear() { entries.removeAll() }
}

/// Logging entry point. Event-driven only (no polling), so the log stays quiet.
///
/// `message` is logged publicly and must not contain hardware identifiers or user data.
/// `details` is logged with private privacy.
enum Log {
    static let subsystem = "com.bachana.DisplayManager"

    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    static func debug(_ category: LogCategory, _ message: String, details: String? = nil) {
        write(.debug, category, message, details: details)
    }

    static func info(_ category: LogCategory, _ message: String, details: String? = nil) {
        write(.info, category, message, details: details)
    }

    static func notice(_ category: LogCategory, _ message: String, details: String? = nil) {
        write(.notice, category, message, details: details)
    }

    static func warning(_ category: LogCategory, _ message: String, details: String? = nil) {
        write(.warning, category, message, details: details)
    }

    static func error(_ category: LogCategory, _ message: String, details: String? = nil) {
        write(.error, category, message, details: details)
    }

    private static func write(_ level: LogLevel, _ category: LogCategory, _ message: String, details: String?) {
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
        if let details, !details.isEmpty {
            logger.log(level: level.osLogType, "\(message, privacy: .public) \(details, privacy: .private)")
        } else {
            logger.log(level: level.osLogType, "\(message, privacy: .public)")
        }
        guard level != .debug else { return }
        let entry = DiagnosticsEntry(date: Date(), category: category, level: level, message: message, details: details)
        Task { @MainActor in DiagnosticsLog.shared.append(entry) }
    }
}

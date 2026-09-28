import Foundation

/// The saved state and the import/export format. Versioned; unknown keys are ignored.
public struct LayoutDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    /// Imports larger than this are refused before decoding.
    public static let maximumImportSize = 5 * 1024 * 1024

    public var version: Int
    public var exportedBy: String?
    /// Array order is the user's order (menu order and rule tie-break).
    public var profiles: [LayoutProfile]
    public var rules: [AutoApplyRule]
    public var knownPorts: [KnownPort]

    public init(
        version: Int = LayoutDocument.currentVersion,
        exportedBy: String? = nil,
        profiles: [LayoutProfile] = [],
        rules: [AutoApplyRule] = [],
        knownPorts: [KnownPort] = []
    ) {
        self.version = version
        self.exportedBy = exportedBy
        self.profiles = profiles
        self.rules = rules
        self.knownPorts = knownPorts
    }

    private enum CodingKeys: String, CodingKey { case version, exportedBy, profiles, rules, knownPorts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedBy = try container.decodeIfPresent(String.self, forKey: .exportedBy)
        profiles = try container.decodeIfPresent([LayoutProfile].self, forKey: .profiles) ?? []
        rules = try container.decodeIfPresent([AutoApplyRule].self, forKey: .rules) ?? []
        knownPorts = try container.decodeIfPresent([KnownPort].self, forKey: .knownPorts) ?? []
    }

    // MARK: Decoding with version handling

    private struct VersionProbe: Decodable {
        var version: Int?
    }

    /// Decodes a document: checks the version first, then migrates older formats.
    public static func decode(_ data: Data) throws -> LayoutDocument {
        let probe: VersionProbe
        do {
            probe = try makeDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw DisplayManagerError.invalidDocument("Not a JSON object: \(error.localizedDescription)")
        }
        guard let version = probe.version else {
            throw DisplayManagerError.invalidDocument("Missing \"version\".")
        }
        if version > currentVersion { throw DisplayManagerError.newerDocumentVersion(version) }
        guard version >= 1 else { throw DisplayManagerError.unsupportedDocumentVersion(version) }
        let migrated = try migrate(data, from: version)
        do {
            var document = try makeDecoder().decode(LayoutDocument.self, from: migrated)
            document.version = currentVersion
            return document
        } catch let error as DecodingError {
            throw DisplayManagerError.invalidDocument(describe(error))
        }
    }

    /// Step migrations `vN → vN+1` go here when the format changes.
    /// Version 1 is the first format, so every accepted version is already current.
    static func migrate(_ data: Data, from version: Int) throws -> Data {
        guard version == currentVersion else { throw DisplayManagerError.unsupportedDocumentVersion(version) }
        return data
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date '\(text)'")
        }
        return decoder
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let components = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return components.isEmpty ? "document" : components.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(path(context)): missing \"\(key.stringValue)\""
        @unknown default:
            return error.localizedDescription
        }
    }
}

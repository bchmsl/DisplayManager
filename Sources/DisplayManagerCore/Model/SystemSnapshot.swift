import Foundation

/// One supported mode from `displayplacer list` ("mode 66: res:1800x1169 hz:120 color_depth:8 scaling:on").
public struct DisplayMode: Hashable, Sendable {
    public var number: Int
    public var resolution: DisplaySize
    public var refreshRate: Int?
    public var colorDepth: Int?
    public var scaling: Bool
    public var isCurrent: Bool

    public init(number: Int, resolution: DisplaySize, refreshRate: Int?, colorDepth: Int?, scaling: Bool, isCurrent: Bool) {
        self.number = number
        self.resolution = resolution
        self.refreshRate = refreshRate
        self.colorDepth = colorDepth
        self.scaling = scaling
        self.isCurrent = isCurrent
    }
}

/// One screen block of `displayplacer list`.
public struct ParsedScreen: Hashable, Sendable {
    public var persistentID: String?
    public var contextualID: Int?
    public var serialID: String?
    public var typeDescription: String?
    public var resolution: DisplaySize?
    public var refreshRate: Int?
    public var colorDepth: Int?
    public var scaling: Bool?
    public var origin: DisplayPoint?
    public var isMain: Bool
    public var rotation: Int?
    public var enabled: Bool?
    /// Rotation the `modes` list was reported for.
    public var modesRotation: Int?
    public var modes: [DisplayMode]
    /// Labels this parser does not know, kept for diagnostics.
    public var extraFields: [String: String]

    public init(
        persistentID: String? = nil,
        contextualID: Int? = nil,
        serialID: String? = nil,
        typeDescription: String? = nil,
        resolution: DisplaySize? = nil,
        refreshRate: Int? = nil,
        colorDepth: Int? = nil,
        scaling: Bool? = nil,
        origin: DisplayPoint? = nil,
        isMain: Bool = false,
        rotation: Int? = nil,
        enabled: Bool? = nil,
        modesRotation: Int? = nil,
        modes: [DisplayMode] = [],
        extraFields: [String: String] = [:]
    ) {
        self.persistentID = persistentID
        self.contextualID = contextualID
        self.serialID = serialID
        self.typeDescription = typeDescription
        self.resolution = resolution
        self.refreshRate = refreshRate
        self.colorDepth = colorDepth
        self.scaling = scaling
        self.origin = origin
        self.isMain = isMain
        self.rotation = rotation
        self.enabled = enabled
        self.modesRotation = modesRotation
        self.modes = modes
        self.extraFields = extraFields
    }

    public var looksBuiltIn: Bool {
        guard let type = typeDescription?.lowercased() else { return false }
        return type.contains("built in") || type.contains("built-in")
    }
}

/// The parsed result of `displayplacer list`.
public struct ParsedList: Hashable, Sendable {
    public var screens: [ParsedScreen]
    /// The authoritative current configuration: the final `displayplacer "…"` line.
    public var configuration: [ScreenSetting]
    public var commandLine: String

    public init(screens: [ParsedScreen], configuration: [ScreenSetting], commandLine: String) {
        self.screens = screens
        self.configuration = configuration
        self.commandLine = commandLine
    }

    public func screen(persistentID: String) -> ParsedScreen? {
        screens.first { $0.persistentID?.caseInsensitiveCompare(persistentID) == .orderedSame }
    }
}

public enum UnidentifiedReason: String, Hashable, Sendable {
    /// No DisplayPort transport with a matching EDID was found.
    case noTransport
    /// Several transports match (identical monitors with identical serials).
    case ambiguous
    /// The transport was found but macOS did not report its port type or number.
    case noPortInfo
    /// Port topology could not be read on this Mac.
    case topologyUnavailable

    public var userMessage: String {
        switch self {
        case .noTransport: "macOS did not report which port this display uses."
        case .ambiguous: "Several identical monitors are connected, so their ports cannot be told apart."
        case .noPortInfo: "macOS did not report the port type or number for this display."
        case .topologyUnavailable: "Port detection is not available on this Mac."
        }
    }
}

/// How a live display is physically connected.
public enum ConnectionState: Hashable, Sendable {
    case builtIn
    case external(ConnectionFingerprint)
    case unidentified(UnidentifiedReason)

    public var fingerprint: ConnectionFingerprint? {
        if case .external(let fingerprint) = self { return fingerprint }
        return nil
    }

    /// Component of the topology signature.
    public var signatureKey: String {
        switch self {
        case .builtIn: "builtin"
        case .external(let fingerprint): fingerprint.key
        case .unidentified: "unidentified"
        }
    }
}

/// A display that is currently connected (online in CoreGraphics or listed by displayplacer).
public struct LiveDisplay: Hashable, Sendable, Identifiable {
    public var persistentID: String
    public var contextualID: Int?
    public var serialID: String?
    public var vendorID: Int?
    public var productID: Int?
    public var serialNumber: Int?
    public var name: String
    public var typeDescription: String?
    public var isBuiltIn: Bool
    public var isMain: Bool
    public var isEnabled: Bool
    /// Current bounds in global points (from CoreGraphics), when known.
    public var bounds: DisplayRect?
    public var rotation: Int
    public var connection: ConnectionState
    /// Diagnostic only, for example "Port-USB-C@3/DisplayPort".
    public var transportDescription: String?
    /// Manufacturer PNP id from EDID, for example "XMI".
    public var manufacturerID: String?

    public init(
        persistentID: String,
        contextualID: Int? = nil,
        serialID: String? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil,
        serialNumber: Int? = nil,
        name: String,
        typeDescription: String? = nil,
        isBuiltIn: Bool,
        isMain: Bool = false,
        isEnabled: Bool = true,
        bounds: DisplayRect? = nil,
        rotation: Int = 0,
        connection: ConnectionState,
        transportDescription: String? = nil,
        manufacturerID: String? = nil
    ) {
        self.persistentID = persistentID
        self.contextualID = contextualID
        self.serialID = serialID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.name = name
        self.typeDescription = typeDescription
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.isEnabled = isEnabled
        self.bounds = bounds
        self.rotation = rotation
        self.connection = connection
        self.transportDescription = transportDescription
        self.manufacturerID = manufacturerID
    }

    public var id: String { persistentID }

    /// Metadata record for saving this display into a profile.
    public var displayInfo: DisplayInfo {
        DisplayInfo(
            persistentID: persistentID,
            contextualID: contextualID,
            serialID: serialID,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            name: name,
            typeDescription: typeDescription,
            isBuiltIn: isBuiltIn,
            bounds: bounds,
            connection: connection.fingerprint
        )
    }
}

/// The set of connected displays and their physical connections.
/// Ignores modes, origins and rotation, so layout changes never look like a connect event.
public struct TopologySignature: Hashable, Sendable, CustomStringConvertible {
    public struct Entry: Hashable, Sendable, Comparable {
        public var persistentID: String
        public var connectionKey: String

        public init(persistentID: String, connectionKey: String) {
            self.persistentID = persistentID
            self.connectionKey = connectionKey
        }

        public static func < (lhs: Entry, rhs: Entry) -> Bool {
            (lhs.persistentID, lhs.connectionKey) < (rhs.persistentID, rhs.connectionKey)
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries.sorted()
    }

    public init(displays: [LiveDisplay]) {
        self.init(entries: displays.map { Entry(persistentID: $0.persistentID, connectionKey: $0.connection.signatureKey) })
    }

    public var description: String {
        entries.map { "\($0.persistentID.prefix(8))@\($0.connectionKey)" }.joined(separator: ", ")
    }
}

public enum TopologyStatus: Hashable, Sendable {
    case available
    case unavailable(String)
}

/// One consistent view of the connected displays, their ports and the current displayplacer configuration.
public struct SystemSnapshot: Hashable, Sendable {
    public var displays: [LiveDisplay]
    /// Nil when displayplacer is missing or its output could not be read.
    public var parsedList: ParsedList?
    public var topologyStatus: TopologyStatus
    public var hostModel: String
    public var capturedAt: Date

    public init(
        displays: [LiveDisplay],
        parsedList: ParsedList?,
        topologyStatus: TopologyStatus,
        hostModel: String,
        capturedAt: Date
    ) {
        self.displays = displays
        self.parsedList = parsedList
        self.topologyStatus = topologyStatus
        self.hostModel = hostModel
        self.capturedAt = capturedAt
    }

    public var signature: TopologySignature { TopologySignature(displays: displays) }

    public var configuration: [ScreenSetting]? { parsedList?.configuration }

    public func display(persistentID: String) -> LiveDisplay? {
        displays.first { $0.persistentID.caseInsensitiveCompare(persistentID) == .orderedSame }
    }

    public var externalDisplays: [LiveDisplay] { displays.filter { !$0.isBuiltIn } }
}

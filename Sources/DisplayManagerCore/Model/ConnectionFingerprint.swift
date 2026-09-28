import Foundation

/// The kind of physical port macOS reports for a display transport (`ParentBuiltInPortType`).
public enum PortKind: Hashable, Sendable, Codable {
    case usbC
    case hdmi
    case other(Int)

    /// Maps the IORegistry port type number. Verified values: 2 = USB-C, 6 = HDMI.
    public init(ioRegistryValue: Int) {
        switch ioRegistryValue {
        case 2: self = .usbC
        case 6: self = .hdmi
        default: self = .other(ioRegistryValue)
        }
    }

    /// Stable string used in fingerprint keys.
    public var rawKey: String {
        switch self {
        case .usbC: "usbc"
        case .hdmi: "hdmi"
        case .other(let value): "type\(value)"
        }
    }

    /// Stable string used in JSON documents.
    public var codingValue: String {
        switch self {
        case .usbC: "usbC"
        case .hdmi: "hdmi"
        case .other(let value): "other-\(value)"
        }
    }

    public init?(codingValue: String) {
        switch codingValue {
        case "usbC": self = .usbC
        case "hdmi": self = .hdmi
        default:
            guard codingValue.hasPrefix("other-"),
                  let value = Int(codingValue.dropFirst("other-".count)),
                  (0...1000).contains(value)
            else { return nil }
            self = .other(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let kind = PortKind(codingValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown port type '\(value)'")
        }
        self = kind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(codingValue)
    }
}

/// Identifies the physical port a display is connected through.
///
/// Port numbers are only meaningful on the same Mac model, so the host model is part of the identity.
/// Matching is plain equality of `key`.
public struct ConnectionFingerprint: Codable, Hashable, Sendable {
    public var hostModel: String
    public var portType: PortKind
    public var portNumber: Int
    /// DisplayPort tunneled through Thunderbolt/USB4 (for example a dock), as opposed to DP Alt Mode or native HDMI.
    public var tunneled: Bool

    public init(hostModel: String, portType: PortKind, portNumber: Int, tunneled: Bool) {
        self.hostModel = hostModel
        self.portType = portType
        self.portNumber = portNumber
        self.tunneled = tunneled
    }

    public var key: String { "\(hostModel)/\(portType.rawKey)@\(portNumber)\(tunneled ? "/tunnel" : "")" }

    /// The label macOS itself implies (`Port-USB-C@3` in IORegistry, `Receptacle: 3` in System Information).
    /// Never a physical position such as "left" or "right".
    public var technicalLabel: String {
        let base: String = switch portType {
        case .usbC: "USB-C Port \(portNumber)"
        case .hdmi: portNumber <= 1 ? "HDMI Port" : "HDMI Port \(portNumber)"
        case .other(let value): "Port \(portNumber) (type \(value))"
        }
        return tunneled ? "\(base) (Thunderbolt)" : base
    }

    public static func == (lhs: ConnectionFingerprint, rhs: ConnectionFingerprint) -> Bool {
        lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

/// A learned port with the user's own name for it.
public struct KnownPort: Codable, Hashable, Sendable, Identifiable {
    public var connection: ConnectionFingerprint
    /// User-given name, for example "Desk Port". Empty means unnamed.
    public var name: String

    public init(connection: ConnectionFingerprint, name: String) {
        self.connection = connection
        self.name = name
    }

    public var id: String { connection.key }

    /// "Desk Port (USB-C Port 3)" when named, otherwise the technical label.
    public var displayLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? connection.technicalLabel : "\(trimmed) (\(connection.technicalLabel))"
    }
}

extension Array where Element == KnownPort {
    /// The label to show for a fingerprint, using the user's name when the port is known.
    public func label(for connection: ConnectionFingerprint) -> String {
        first { $0.connection == connection }?.displayLabel ?? connection.technicalLabel
    }
}

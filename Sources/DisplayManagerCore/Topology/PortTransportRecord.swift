import Foundation

/// Plain copy of one `IOPortTransportStateDisplayPort` IORegistry node.
///
/// Produced by the app's IOKit reader; Core only consumes it. Every hardware property is optional
/// because these properties are not a documented contract.
public struct PortTransportRecord: Hashable, Sendable {
    public var transportDescription: String?
    /// `ParentBuiltInPortType` (2 = USB-C, 6 = HDMI).
    public var builtInPortType: Int?
    /// `ParentBuiltInPortNumber`.
    public var builtInPortNumber: Int?
    public var parentPortType: Int?
    public var parentPortNumber: Int?
    public var parentPortBuiltIn: Bool?
    /// `PortType` / `PortNumber` of the nearest `AppleHPMInterfaceType*` ancestor.
    public var ancestorPortType: Int?
    public var ancestorPortNumber: Int?
    public var tunneled: Bool
    public var active: Bool
    /// `HPD_State == 2` (hot plug detect high).
    public var hotPlugDetected: Bool
    public var sinkCount: Int?
    public var edid: Data?
    public var parentName: String?
    public var parentLocation: String?

    public init(
        transportDescription: String? = nil,
        builtInPortType: Int? = nil,
        builtInPortNumber: Int? = nil,
        parentPortType: Int? = nil,
        parentPortNumber: Int? = nil,
        parentPortBuiltIn: Bool? = nil,
        ancestorPortType: Int? = nil,
        ancestorPortNumber: Int? = nil,
        tunneled: Bool = false,
        active: Bool = false,
        hotPlugDetected: Bool = false,
        sinkCount: Int? = nil,
        edid: Data? = nil,
        parentName: String? = nil,
        parentLocation: String? = nil
    ) {
        self.transportDescription = transportDescription
        self.builtInPortType = builtInPortType
        self.builtInPortNumber = builtInPortNumber
        self.parentPortType = parentPortType
        self.parentPortNumber = parentPortNumber
        self.parentPortBuiltIn = parentPortBuiltIn
        self.ancestorPortType = ancestorPortType
        self.ancestorPortNumber = ancestorPortNumber
        self.tunneled = tunneled
        self.active = active
        self.hotPlugDetected = hotPlugDetected
        self.sinkCount = sinkCount
        self.edid = edid
        self.parentName = parentName
        self.parentLocation = parentLocation
    }

    /// True when something is plugged into this transport right now.
    public var isLive: Bool { active || hotPlugDetected }

    public var edidInfo: EDIDInfo? { edid.flatMap(EDIDInfo.parse) }

    /// Port type and number, using the fallback order from the plan:
    /// built-in port properties, then parent port properties when built in, then the HPM ancestor.
    public var derivedPort: (kind: PortKind, number: Int)? {
        if let type = builtInPortType, let number = builtInPortNumber {
            return (PortKind(ioRegistryValue: type), number)
        }
        if parentPortBuiltIn == true, let type = parentPortType, let number = parentPortNumber {
            return (PortKind(ioRegistryValue: type), number)
        }
        if let type = ancestorPortType, let number = ancestorPortNumber {
            return (PortKind(ioRegistryValue: type), number)
        }
        return nil
    }
}

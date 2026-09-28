import Foundation

/// Metadata about a display, saved with a profile at save time.
///
/// Used to find the same monitor again (identity), to draw previews, and to remember the port the
/// monitor used when the layout was saved. `ScreenSetting` is what gets applied.
public struct DisplayInfo: Codable, Hashable, Sendable {
    public var persistentID: String
    public var contextualID: Int?
    public var serialID: String?
    public var vendorID: Int?
    public var productID: Int?
    public var serialNumber: Int?
    public var name: String
    public var typeDescription: String?
    public var isBuiltIn: Bool
    public var bounds: DisplayRect?
    public var connection: ConnectionFingerprint?

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
        bounds: DisplayRect? = nil,
        connection: ConnectionFingerprint? = nil
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
        self.bounds = bounds
        self.connection = connection
    }

    private enum CodingKeys: String, CodingKey {
        case persistentID, contextualID, serialID, vendorID, productID, serialNumber
        case name, typeDescription, isBuiltIn, bounds, connection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        persistentID = try container.decode(String.self, forKey: .persistentID)
        contextualID = try container.decodeIfPresent(Int.self, forKey: .contextualID)
        serialID = try container.decodeIfPresent(String.self, forKey: .serialID)
        vendorID = try container.decodeIfPresent(Int.self, forKey: .vendorID)
        productID = try container.decodeIfPresent(Int.self, forKey: .productID)
        serialNumber = try container.decodeIfPresent(Int.self, forKey: .serialNumber)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? persistentID
        typeDescription = try container.decodeIfPresent(String.self, forKey: .typeDescription)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        bounds = try container.decodeIfPresent(DisplayRect.self, forKey: .bounds)
        connection = try container.decodeIfPresent(ConnectionFingerprint.self, forKey: .connection)
    }
}

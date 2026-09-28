import Foundation

/// Identity fields decoded from the first 128-byte EDID block.
public struct EDIDInfo: Hashable, Sendable {
    /// Big-endian manufacturer code, equal to `CGDisplayVendorNumber`.
    public var vendorCode: Int
    /// Three-letter PNP id, for example "XMI".
    public var manufacturerID: String
    /// Little-endian product code, equal to `CGDisplayModelNumber`.
    public var productCode: Int
    /// Little-endian serial number, equal to `CGDisplaySerialNumber`.
    public var serialNumber: Int
    /// Monitor name descriptor (0xFC), for example "Mi Monitor".
    public var displayName: String?

    public init(vendorCode: Int, manufacturerID: String, productCode: Int, serialNumber: Int, displayName: String?) {
        self.vendorCode = vendorCode
        self.manufacturerID = manufacturerID
        self.productCode = productCode
        self.serialNumber = serialNumber
        self.displayName = displayName
    }

    private static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

    /// Returns nil for data that is too short or has no EDID header. The checksum is not required,
    /// because some monitors ship with a wrong one and macOS still uses their EDID.
    public static func parse(_ data: Data) -> EDIDInfo? {
        let bytes = [UInt8](data.prefix(128))
        guard bytes.count >= 128, Array(bytes[0..<8]) == header else { return nil }

        let vendor = Int(bytes[8]) << 8 | Int(bytes[9])
        let letters = [(vendor >> 10) & 0x1F, (vendor >> 5) & 0x1F, vendor & 0x1F]
        let manufacturer = String(letters.map { value -> Character in
            (1...26).contains(value) ? Character(UnicodeScalar(UInt8(64 + value))) : "?"
        })
        let product = Int(bytes[10]) | Int(bytes[11]) << 8
        let serial = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24

        var name: String?
        for offset in stride(from: 54, through: 108, by: 18) {
            let descriptor = bytes[offset..<(offset + 18)]
            let start = descriptor.startIndex
            guard descriptor[start] == 0, descriptor[start + 1] == 0, descriptor[start + 2] == 0 else { continue }
            if descriptor[start + 3] == 0xFC {
                name = descriptorText(Array(descriptor[(start + 5)...]))
            }
        }
        return EDIDInfo(vendorCode: vendor, manufacturerID: manufacturer, productCode: product, serialNumber: serial, displayName: name)
    }

    private static func descriptorText(_ bytes: [UInt8]) -> String? {
        let textBytes = bytes.prefix { $0 != 0x0A && $0 != 0x00 }
        guard let text = String(bytes: textBytes, encoding: .ascii) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

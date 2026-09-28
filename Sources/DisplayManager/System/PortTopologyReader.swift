import DisplayManagerCore
import Foundation
import IOKit

/// Reads the physical port of each DisplayPort transport from the IORegistry.
///
/// Uses public IOKit calls, but the classes and properties are not a documented contract, so every
/// value is optional and a missing class means "not available on this Mac", never a crash.
enum PortTopologyReader {
    static let transportClass = "IOPortTransportStateDisplayPort"
    /// Base class of every port transport node (CC, USB2, USB3, DisplayPort, …).
    static let transportBaseClass = "IOPortTransportState"

    struct Result: Sendable {
        var records: [PortTransportRecord]
        var status: TopologyStatus
    }

    static func read() -> Result {
        var records: [PortTransportRecord] = []
        let status = forEachService(matching: transportClass) { service in
            records.append(record(for: service))
        }
        if case .unavailable = status { return Result(records: [], status: status) }
        if records.isEmpty, !hasAnyService(matching: transportBaseClass) {
            // Macs without port transport nodes (for example Intel Macs or older macOS versions).
            return Result(records: [], status: .unavailable("macOS does not report port transports on this Mac."))
        }
        return Result(records: records, status: .available)
    }

    /// The Mac model, for example "Mac16,8". Port numbers are only meaningful on the same model.
    static func hostModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "UnknownMac" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "UnknownMac" }
        let model = decodeCString(buffer)
        return model.isEmpty ? "UnknownMac" : model
    }

    // MARK: Reading

    private static func record(for service: io_service_t) -> PortTransportRecord {
        let properties = copyProperties(service)
        var record = PortTransportRecord(
            transportDescription: properties["TransportDescription"] as? String,
            builtInPortType: intValue(properties["ParentBuiltInPortType"]),
            builtInPortNumber: intValue(properties["ParentBuiltInPortNumber"]),
            parentPortType: intValue(properties["ParentPortType"]),
            parentPortNumber: intValue(properties["ParentPortNumber"]),
            parentPortBuiltIn: boolValue(properties["ParentPortBuiltIn"]),
            tunneled: boolValue(properties["Tunneled"]) ?? false,
            active: boolValue(properties["Active"]) ?? false,
            hotPlugDetected: intValue(properties["HPD_State"]) == 2,
            sinkCount: intValue(properties["SinkCount"]),
            edid: properties["EDID"] as? Data
        )

        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            record.parentName = name(of: parent)
            record.parentLocation = location(of: parent)
            IOObjectRelease(parent)
        }
        if record.builtInPortNumber == nil, let ancestor = hpmAncestorPort(of: service) {
            record.ancestorPortType = ancestor.type
            record.ancestorPortNumber = ancestor.number
        }
        return record
    }

    /// `PortType` and `PortNumber` of the nearest `AppleHPMInterfaceType*` ancestor (fallback step 3).
    private static func hpmAncestorPort(of service: io_service_t) -> (type: Int?, number: Int?)? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<8 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
            let className = IOObjectCopyClass(current)?.takeRetainedValue() as String? ?? ""
            if className.hasPrefix("AppleHPMInterfaceType") {
                let properties = copyProperties(current)
                return (intValue(properties["PortType"]), intValue(properties["PortNumber"]))
            }
        }
        return nil
    }

    // MARK: IOKit helpers

    /// Calls `body` for each matching service. Returns `.unavailable` when the registry cannot be queried.
    private static func forEachService(matching className: String, _ body: (io_service_t) -> Void) -> TopologyStatus {
        guard let matching = IOServiceMatching(className) else {
            return .unavailable("IOServiceMatching failed for \(className).")
        }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return .unavailable("IOServiceGetMatchingServices failed (\(result)).")
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            body(service)
            IOObjectRelease(service)
        }
        return .available
    }

    private static func hasAnyService(matching className: String) -> Bool {
        var found = false
        _ = forEachService(matching: className) { _ in found = true }
        return found
    }

    private static func copyProperties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private static func name(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        return decodeCString(buffer.map { UInt8(bitPattern: $0) })
    }

    private static func location(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetLocationInPlane(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return nil }
        return decodeCString(buffer.map { UInt8(bitPattern: $0) })
    }

    private static func decodeCString(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

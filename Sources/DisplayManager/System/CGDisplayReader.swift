import AppKit
import CoreGraphics
import DisplayManagerCore

/// Reads the online displays from CoreGraphics. Synchronous and fast; no subprocess.
@MainActor
enum CGDisplayReader {
    static func onlineDisplays() -> [CGDisplayRecord] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        let names = screenNames()
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return CGDisplayRecord(
                displayID: id,
                uuid: uuidString(for: id),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                vendorNumber: Int(CGDisplayVendorNumber(id)),
                modelNumber: Int(CGDisplayModelNumber(id)),
                serialNumber: Int(CGDisplaySerialNumber(id)),
                bounds: DisplayRect(
                    x: Int(bounds.origin.x.rounded()),
                    y: Int(bounds.origin.y.rounded()),
                    width: Int(bounds.width.rounded()),
                    height: Int(bounds.height.rounded())),
                rotation: Int(CGDisplayRotation(id).rounded()),
                localizedName: names[id]
            )
        }
    }

    private static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// `NSScreen.localizedName` by display id. Mirrored or disabled displays may have no screen.
    private static func screenNames() -> [CGDirectDisplayID: String] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        var result: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            result[number.uint32Value] = screen.localizedName
        }
        return result
    }
}

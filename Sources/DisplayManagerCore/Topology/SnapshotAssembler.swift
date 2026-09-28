import Foundation

/// Plain copy of what CoreGraphics reports for one online display.
public struct CGDisplayRecord: Hashable, Sendable {
    public var displayID: UInt32
    public var uuid: String?
    public var isBuiltIn: Bool
    public var isMain: Bool
    public var vendorNumber: Int
    public var modelNumber: Int
    public var serialNumber: Int
    public var bounds: DisplayRect
    public var rotation: Int
    /// `NSScreen.localizedName`, when the display has a screen.
    public var localizedName: String?

    public init(
        displayID: UInt32,
        uuid: String?,
        isBuiltIn: Bool,
        isMain: Bool,
        vendorNumber: Int,
        modelNumber: Int,
        serialNumber: Int,
        bounds: DisplayRect,
        rotation: Int,
        localizedName: String?
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.bounds = bounds
        self.rotation = rotation
        self.localizedName = localizedName
    }
}

/// Joins CoreGraphics records, IORegistry port transports and displayplacer output into one snapshot.
public enum SnapshotAssembler {
    public static func assemble(
        cgDisplays: [CGDisplayRecord],
        transports: [PortTransportRecord],
        topologyStatus: TopologyStatus,
        parsedList: ParsedList?,
        hostModel: String,
        capturedAt: Date
    ) -> SystemSnapshot {
        let displays = liveDisplays(
            cgDisplays: cgDisplays,
            transports: transports,
            topologyStatus: topologyStatus,
            parsedScreens: parsedList?.screens ?? [],
            hostModel: hostModel
        )
        return SystemSnapshot(
            displays: displays,
            parsedList: parsedList,
            topologyStatus: topologyStatus,
            hostModel: hostModel,
            capturedAt: capturedAt
        )
    }

    public static func liveDisplays(
        cgDisplays: [CGDisplayRecord],
        transports: [PortTransportRecord],
        topologyStatus: TopologyStatus,
        parsedScreens: [ParsedScreen],
        hostModel: String
    ) -> [LiveDisplay] {
        let liveTransports = transports.compactMap { record -> (PortTransportRecord, EDIDInfo)? in
            guard record.isLive, let info = record.edidInfo else { return nil }
            return (record, info)
        }
        var usedScreens = Set<Int>()
        var result: [LiveDisplay] = []

        for cg in cgDisplays {
            let screenIndex = parsedScreens.indices.first { index in
                guard !usedScreens.contains(index) else { return false }
                let screen = parsedScreens[index]
                if let uuid = cg.uuid, let persistent = screen.persistentID {
                    return persistent.caseInsensitiveCompare(uuid) == .orderedSame
                }
                return screen.contextualID == Int(cg.displayID)
            } ?? parsedScreens.indices.first { index in
                !usedScreens.contains(index) && parsedScreens[index].contextualID == Int(cg.displayID)
            }
            if let screenIndex { usedScreens.insert(screenIndex) }
            let screen = screenIndex.map { parsedScreens[$0] }

            var transportDescription: String?
            var manufacturerID: String?
            var edidName: String?
            let connection: ConnectionState
            if cg.isBuiltIn {
                connection = .builtIn
            } else if case .unavailable = topologyStatus {
                connection = .unidentified(.topologyUnavailable)
            } else {
                let candidates = liveTransports.filter { _, info in
                    info.vendorCode == cg.vendorNumber
                        && info.productCode == cg.modelNumber
                        && info.serialNumber == cg.serialNumber
                }
                let sameIdentityDisplays = cgDisplays.filter {
                    !$0.isBuiltIn && $0.vendorNumber == cg.vendorNumber
                        && $0.modelNumber == cg.modelNumber && $0.serialNumber == cg.serialNumber
                }
                if candidates.count == 1, sameIdentityDisplays.count == 1, let match = candidates.first {
                    let (record, info) = match
                    transportDescription = record.transportDescription
                    manufacturerID = info.manufacturerID
                    edidName = info.displayName
                    if let port = record.derivedPort {
                        connection = .external(ConnectionFingerprint(
                            hostModel: hostModel, portType: port.kind, portNumber: port.number, tunneled: record.tunneled))
                    } else {
                        connection = .unidentified(.noPortInfo)
                    }
                } else if candidates.isEmpty {
                    connection = .unidentified(.noTransport)
                } else {
                    connection = .unidentified(.ambiguous)
                }
            }

            let persistentID = cg.uuid ?? screen?.persistentID ?? "cg-\(cg.displayID)"
            result.append(LiveDisplay(
                persistentID: persistentID,
                contextualID: Int(cg.displayID),
                serialID: screen?.serialID,
                vendorID: cg.vendorNumber,
                productID: cg.modelNumber,
                serialNumber: cg.serialNumber,
                name: displayName(localized: cg.localizedName, edidName: edidName, isBuiltIn: cg.isBuiltIn, screen: screen, id: cg.displayID),
                typeDescription: screen?.typeDescription,
                isBuiltIn: cg.isBuiltIn,
                isMain: cg.isMain,
                isEnabled: screen?.enabled ?? true,
                bounds: cg.bounds,
                rotation: cg.rotation,
                connection: connection,
                transportDescription: transportDescription,
                manufacturerID: manufacturerID
            ))
        }

        // Screens displayplacer lists that CoreGraphics does not report as online (for example disabled ones).
        for (index, screen) in parsedScreens.enumerated() where !usedScreens.contains(index) {
            guard let persistentID = screen.persistentID ?? screen.contextualID.map({ "cg-\($0)" }) else { continue }
            let builtIn = screen.looksBuiltIn
            result.append(LiveDisplay(
                persistentID: persistentID,
                contextualID: screen.contextualID,
                serialID: screen.serialID,
                name: displayName(localized: nil, edidName: nil, isBuiltIn: builtIn, screen: screen, id: UInt32(screen.contextualID ?? 0)),
                typeDescription: screen.typeDescription,
                isBuiltIn: builtIn,
                isMain: screen.isMain,
                isEnabled: screen.enabled ?? false,
                bounds: nil,
                rotation: screen.rotation ?? 0,
                connection: builtIn ? .builtIn : .unidentified(.noTransport)
            ))
        }
        return result
    }

    private static func displayName(localized: String?, edidName: String?, isBuiltIn: Bool, screen: ParsedScreen?, id: UInt32) -> String {
        if let localized, !localized.isEmpty { return localized }
        if let edidName, !edidName.isEmpty { return edidName }
        if isBuiltIn { return "Built-in Display" }
        if let type = screen?.typeDescription, !type.isEmpty { return type.prefix(1).uppercased() + type.dropFirst() }
        return "Display \(id)"
    }
}

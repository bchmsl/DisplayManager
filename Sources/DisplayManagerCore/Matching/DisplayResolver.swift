import Foundation

/// Mapping from a profile's saved display ids to connected displays.
public struct DisplayResolution: Hashable, Sendable {
    public var savedToLive: [String: String]
    public var unresolvedSavedIDs: [String]

    public init(savedToLive: [String: String], unresolvedSavedIDs: [String]) {
        self.savedToLive = savedToLive
        self.unresolvedSavedIDs = unresolvedSavedIDs
    }

    public func liveID(forSaved savedID: String) -> String? { savedToLive[savedID] }

    public var resolvedLiveIDs: Set<String> { Set(savedToLive.values) }
}

/// Finds the connected display for each saved display, at most one each way.
///
/// Order: same persistent UUID, then the built-in display, then a unique (vendor, product, serial) match
/// with a non-zero serial. Anything else stays unresolved.
public enum DisplayResolver {
    public static func resolve(saved: [DisplayInfo], live: [LiveDisplay]) -> DisplayResolution {
        var mapping: [String: String] = [:]
        var takenLive = Set<String>()
        var remaining = uniqueByID(saved)

        // 1. Same persistent UUID.
        remaining.removeAll { info in
            guard let match = live.first(where: {
                !takenLive.contains($0.persistentID) && $0.persistentID.caseInsensitiveCompare(info.persistentID) == .orderedSame
            }) else { return false }
            mapping[info.persistentID] = match.persistentID
            takenLive.insert(match.persistentID)
            return true
        }

        // 2. Built-in display.
        let liveBuiltIns = live.filter(\.isBuiltIn)
        let savedBuiltIns = remaining.filter(\.isBuiltIn)
        if liveBuiltIns.count == 1, savedBuiltIns.count == 1,
           let liveBuiltIn = liveBuiltIns.first, !takenLive.contains(liveBuiltIn.persistentID),
           let savedBuiltIn = savedBuiltIns.first {
            mapping[savedBuiltIn.persistentID] = liveBuiltIn.persistentID
            takenLive.insert(liveBuiltIn.persistentID)
            remaining.removeAll { $0.persistentID == savedBuiltIn.persistentID }
        }

        // 3. Unique (vendor, product, serial) with a real serial number.
        let snapshotOfRemaining = remaining
        remaining.removeAll { info in
            guard !info.isBuiltIn, let key = identityKey(vendor: info.vendorID, product: info.productID, serial: info.serialNumber) else {
                return false
            }
            let savedWithKey = snapshotOfRemaining.filter {
                identityKey(vendor: $0.vendorID, product: $0.productID, serial: $0.serialNumber) == key
            }
            let liveWithKey = live.filter {
                !$0.isBuiltIn && identityKey(vendor: $0.vendorID, product: $0.productID, serial: $0.serialNumber) == key
            }
            guard savedWithKey.count == 1, liveWithKey.count == 1, let match = liveWithKey.first,
                  !takenLive.contains(match.persistentID)
            else { return false }
            mapping[info.persistentID] = match.persistentID
            takenLive.insert(match.persistentID)
            return true
        }

        return DisplayResolution(savedToLive: mapping, unresolvedSavedIDs: remaining.map(\.persistentID))
    }

    public static func resolve(profile: LayoutProfile, snapshot: SystemSnapshot) -> DisplayResolution {
        resolve(saved: profile.displayIdentities, live: snapshot.displays)
    }

    private struct IdentityKey: Hashable {
        var vendor: Int
        var product: Int
        var serial: Int
    }

    private static func identityKey(vendor: Int?, product: Int?, serial: Int?) -> IdentityKey? {
        guard let vendor, let product, let serial, serial != 0 else { return nil }
        return IdentityKey(vendor: vendor, product: product, serial: serial)
    }

    private static func uniqueByID(_ saved: [DisplayInfo]) -> [DisplayInfo] {
        var seen = Set<String>()
        return saved.filter { seen.insert($0.persistentID).inserted }
    }
}

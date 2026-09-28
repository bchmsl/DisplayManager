import Foundation

/// One reason why the current configuration differs from a profile.
public enum LayoutDifference: Hashable, Sendable, CustomStringConvertible {
    case displayNotConnected(name: String)
    case extraDisplay(name: String)
    case mirroringDiffers(names: [String])
    case shouldBeDisabled(name: String)
    case shouldBeEnabled(name: String)
    case resolution(name: String, expected: DisplaySize, actual: DisplaySize?)
    case refreshRate(name: String, expected: Int, actual: Int)
    case colorDepth(name: String, expected: Int, actual: Int)
    case scaling(name: String, expected: Bool, actual: Bool?)
    case origin(name: String, expected: DisplayPoint, actual: DisplayPoint?)
    case rotation(name: String, expected: Int, actual: Int)
    case configurationUnavailable

    public var description: String {
        switch self {
        case .displayNotConnected(let name): "\(name) is not connected"
        case .extraDisplay(let name): "\(name) is connected but not part of this layout"
        case .mirroringDiffers(let names): "Mirroring differs for \(names.joined(separator: ", "))"
        case .shouldBeDisabled(let name): "\(name) should be turned off"
        case .shouldBeEnabled(let name): "\(name) should be turned on"
        case .resolution(let name, let expected, let actual):
            "\(name) resolution is \(actual.map(\.description) ?? "unknown"), expected \(expected)"
        case .refreshRate(let name, let expected, let actual): "\(name) refresh rate is \(actual) Hz, expected \(expected) Hz"
        case .colorDepth(let name, let expected, let actual): "\(name) color depth is \(actual), expected \(expected)"
        case .scaling(let name, let expected, let actual):
            "\(name) scaling is \(actual.map { $0 ? "on" : "off" } ?? "unknown"), expected \(expected ? "on" : "off")"
        case .origin(let name, let expected, let actual):
            "\(name) position is \(actual.map(\.description) ?? "unknown"), expected \(expected)"
        case .rotation(let name, let expected, let actual): "\(name) rotation is \(actual)°, expected \(expected)°"
        case .configurationUnavailable: "The current display configuration is not available"
        }
    }
}

public enum LayoutComparison: Hashable, Sendable {
    case match
    case mismatch([LayoutDifference])

    public var isMatch: Bool { self == .match }

    public var differences: [LayoutDifference] {
        if case .mismatch(let differences) = self { return differences }
        return []
    }
}

/// Deterministic comparison between a profile and the current configuration.
public enum LayoutComparator {
    public enum Scope: Sendable {
        /// The whole configuration must match (current layout detection, auto-apply "already correct").
        case fullLayout
        /// Only the profile's own displays are checked (apply verification).
        case profileDisplaysOnly
    }

    /// Origins may differ by this many points on each axis (macOS nudges edges when snapping).
    public static let originTolerance = 2

    public static func compare(profile: LayoutProfile, snapshot: SystemSnapshot, scope: Scope) -> LayoutComparison {
        guard let live = snapshot.configuration else { return .mismatch([.configurationUnavailable]) }
        let resolution = DisplayResolver.resolve(profile: profile, snapshot: snapshot)
        return compare(profile: profile, resolution: resolution, liveConfiguration: live, liveDisplays: snapshot.displays, scope: scope)
    }

    public static func compare(
        profile: LayoutProfile,
        resolution: DisplayResolution,
        liveConfiguration: [ScreenSetting],
        liveDisplays: [LiveDisplay],
        scope: Scope
    ) -> LayoutComparison {
        var differences: [LayoutDifference] = []
        let liveNames = Dictionary(liveDisplays.map { ($0.persistentID.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        func liveName(_ id: String) -> String { liveNames[id.lowercased()] ?? "Display \(id.prefix(8))" }

        // Live groups keyed by lowercased ids.
        let liveGroups = liveConfiguration.map { screen in
            (ids: Set(screen.displayIDs.map { $0.lowercased() }), screen: screen)
        }
        func liveGroup(containing id: String) -> (ids: Set<String>, screen: ScreenSetting)? {
            liveGroups.first { $0.ids.contains(id.lowercased()) }
        }
        let connectedIDs = Set(liveDisplays.map { $0.persistentID.lowercased() })

        var coveredLiveIDs = Set<String>()
        for saved in profile.screens {
            let names = saved.displayIDs.map { profile.displayInfo(for: $0).name }
            let mapped = saved.displayIDs.map { resolution.liveID(forSaved: $0) }

            guard saved.enabled else {
                for (index, liveID) in mapped.enumerated() {
                    guard let liveID else { continue }
                    coveredLiveIDs.insert(liveID.lowercased())
                    if let group = liveGroup(containing: liveID), group.screen.enabled {
                        differences.append(.shouldBeDisabled(name: names[index]))
                    }
                }
                continue
            }

            let missing = zip(names, mapped).filter { _, liveID in
                guard let liveID else { return true }
                return !connectedIDs.contains(liveID.lowercased())
            }
            if !missing.isEmpty {
                differences += missing.map { .displayNotConnected(name: $0.0) }
                continue
            }
            let liveIDs = mapped.compactMap { $0?.lowercased() }
            let name = names.joined(separator: " + ")
            coveredLiveIDs.formUnion(liveIDs)
            guard let firstID = liveIDs.first, let group = liveGroup(containing: firstID) else {
                differences.append(.displayNotConnected(name: name))
                continue
            }
            if group.ids != Set(liveIDs) {
                differences.append(.mirroringDiffers(names: names))
                continue
            }
            differences += fieldDifferences(expected: saved, actual: group.screen, name: name)
        }

        if scope == .fullLayout {
            for group in liveGroups where group.screen.enabled {
                for id in group.ids.sorted() where !coveredLiveIDs.contains(id) {
                    differences.append(.extraDisplay(name: liveName(id)))
                }
            }
        }
        return differences.isEmpty ? .match : .mismatch(differences)
    }

    static func fieldDifferences(expected: ScreenSetting, actual: ScreenSetting, name: String) -> [LayoutDifference] {
        guard actual.enabled else { return [.shouldBeEnabled(name: name)] }
        var differences: [LayoutDifference] = []
        if let resolution = expected.resolution, resolution != actual.resolution {
            differences.append(.resolution(name: name, expected: resolution, actual: actual.resolution))
        }
        if let hz = expected.refreshRate, let actualHz = actual.refreshRate, hz != actualHz {
            differences.append(.refreshRate(name: name, expected: hz, actual: actualHz))
        }
        if let depth = expected.colorDepth, let actualDepth = actual.colorDepth, depth != actualDepth {
            differences.append(.colorDepth(name: name, expected: depth, actual: actualDepth))
        }
        if let scaling = expected.scaling, scaling != actual.scaling {
            differences.append(.scaling(name: name, expected: scaling, actual: actual.scaling))
        }
        if let origin = expected.origin {
            if let actualOrigin = actual.origin {
                if abs(origin.x - actualOrigin.x) > originTolerance || abs(origin.y - actualOrigin.y) > originTolerance {
                    differences.append(.origin(name: name, expected: origin, actual: actualOrigin))
                }
            } else {
                differences.append(.origin(name: name, expected: origin, actual: nil))
            }
        }
        if expected.effectiveRotation != actual.effectiveRotation {
            differences.append(.rotation(name: name, expected: expected.effectiveRotation, actual: actual.effectiveRotation))
        }
        return differences
    }

    /// The first profile in user order that matches the whole configuration.
    public static func currentProfile(in profiles: [LayoutProfile], snapshot: SystemSnapshot) -> LayoutProfile? {
        profiles.first { compare(profile: $0, snapshot: snapshot, scope: .fullLayout).isMatch }
    }
}

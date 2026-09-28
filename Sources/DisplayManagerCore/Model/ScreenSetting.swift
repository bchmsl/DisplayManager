import Foundation

/// One screen spec of a displayplacer command: a single display or a mirror set.
///
/// `displayIDs` has one id for a single display. A mirror set lists several ids; the first one is the
/// display macOS optimizes the mirrored mode for (displayplacer's `id:A+B`).
public struct ScreenSetting: Codable, Hashable, Sendable {
    public var displayIDs: [String]
    public var enabled: Bool
    public var resolution: DisplaySize?
    public var refreshRate: Int?
    public var colorDepth: Int?
    public var scaling: Bool?
    public var origin: DisplayPoint?
    public var rotation: Int?
    /// Tokens this app does not interpret (for example `mode:12` or `quiet:true`). Kept and re-emitted.
    public var extraArguments: [String: String]

    public init(
        displayIDs: [String],
        enabled: Bool = true,
        resolution: DisplaySize? = nil,
        refreshRate: Int? = nil,
        colorDepth: Int? = nil,
        scaling: Bool? = nil,
        origin: DisplayPoint? = nil,
        rotation: Int? = nil,
        extraArguments: [String: String] = [:]
    ) {
        self.displayIDs = displayIDs
        self.enabled = enabled
        self.resolution = resolution
        self.refreshRate = refreshRate
        self.colorDepth = colorDepth
        self.scaling = scaling
        self.origin = origin
        self.rotation = rotation
        self.extraArguments = extraArguments
    }

    public var isMirrorSet: Bool { displayIDs.count > 1 }

    /// The first id, which displayplacer uses for mode lookups of a mirror set.
    public var primaryID: String? { displayIDs.first }

    /// Rotation with displayplacer's default (0) applied.
    public var effectiveRotation: Int { rotation ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case displayIDs, enabled, resolution, refreshRate, colorDepth, scaling, origin, rotation, extraArguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayIDs = try container.decode([String].self, forKey: .displayIDs)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        resolution = try container.decodeIfPresent(DisplaySize.self, forKey: .resolution)
        refreshRate = try container.decodeIfPresent(Int.self, forKey: .refreshRate)
        colorDepth = try container.decodeIfPresent(Int.self, forKey: .colorDepth)
        scaling = try container.decodeIfPresent(Bool.self, forKey: .scaling)
        origin = try container.decodeIfPresent(DisplayPoint.self, forKey: .origin)
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation)
        extraArguments = try container.decodeIfPresent([String: String].self, forKey: .extraArguments) ?? [:]
    }
}

import Foundation

/// A saved display layout.
public struct LayoutProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// What gets applied, in displayplacer terms.
    public var screens: [ScreenSetting]
    /// Metadata for identity matching and previews.
    public var displays: [DisplayInfo]
    public var shortcut: KeyShortcut?
    /// The displayplacer command reported when the layout was saved (informational).
    public var sourceCommand: String?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        updatedAt: Date,
        screens: [ScreenSetting],
        displays: [DisplayInfo],
        shortcut: KeyShortcut? = nil,
        sourceCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.screens = screens
        self.displays = displays
        self.shortcut = shortcut
        self.sourceCommand = sourceCommand
    }

    /// Every display id the profile mentions, enabled or disabled, in screen order.
    public var allDisplayIDs: [String] { screens.flatMap(\.displayIDs) }

    /// Ids of displays the profile turns on.
    public var enabledDisplayIDs: [String] { screens.filter(\.enabled).flatMap(\.displayIDs) }

    /// Saved metadata for an id. Profiles imported without metadata get a minimal record.
    public func displayInfo(for persistentID: String) -> DisplayInfo {
        displays.first { $0.persistentID == persistentID }
            ?? DisplayInfo(persistentID: persistentID, name: "Display \(persistentID.prefix(8))", isBuiltIn: false)
    }

    /// Metadata records for every display the profile mentions, in screen order.
    public var displayIdentities: [DisplayInfo] { allDisplayIDs.map(displayInfo(for:)) }

    public var externalDisplays: [DisplayInfo] { displayIdentities.filter { !$0.isBuiltIn } }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, screens, displays, shortcut, sourceCommand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let now = Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        screens = try container.decode([ScreenSetting].self, forKey: .screens)
        displays = try container.decodeIfPresent([DisplayInfo].self, forKey: .displays) ?? []
        shortcut = try container.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
        sourceCommand = try container.decodeIfPresent(String.self, forKey: .sourceCommand)
    }
}

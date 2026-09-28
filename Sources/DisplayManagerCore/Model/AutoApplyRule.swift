import Foundation

/// What caused an automation evaluation.
public enum AutomationTrigger: String, Codable, Hashable, Sendable, CaseIterable {
    case launch
    case displayConnect
    case wake
}

public struct RuleTriggers: Codable, Hashable, Sendable {
    public var launch: Bool
    public var displayConnect: Bool
    public var wake: Bool

    public init(launch: Bool = true, displayConnect: Bool = true, wake: Bool = true) {
        self.launch = launch
        self.displayConnect = displayConnect
        self.wake = wake
    }

    public func contains(_ trigger: AutomationTrigger) -> Bool {
        switch trigger {
        case .launch: launch
        case .displayConnect: displayConnect
        case .wake: wake
        }
    }

    public var isEmpty: Bool { !launch && !displayConnect && !wake }

    private enum CodingKeys: String, CodingKey { case launch, displayConnect, wake }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launch = try container.decodeIfPresent(Bool.self, forKey: .launch) ?? true
        displayConnect = try container.decodeIfPresent(Bool.self, forKey: .displayConnect) ?? true
        wake = try container.decodeIfPresent(Bool.self, forKey: .wake) ?? true
    }
}

/// Requires one display of the profile to be connected through a specific physical port.
public struct ConnectionRequirement: Codable, Hashable, Sendable {
    /// The persistent id of the display as saved in the profile.
    public var persistentID: String
    public var connection: ConnectionFingerprint

    public init(persistentID: String, connection: ConnectionFingerprint) {
        self.persistentID = persistentID
        self.connection = connection
    }
}

/// Applies a profile automatically when the connected displays (and optionally their ports) match.
///
/// The display-set condition is implicit: the connected displays must be exactly the profile's displays.
public struct AutoApplyRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var isEnabled: Bool
    public var connectionRequirements: [ConnectionRequirement]
    public var triggers: RuleTriggers

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        isEnabled: Bool = true,
        connectionRequirements: [ConnectionRequirement] = [],
        triggers: RuleTriggers = RuleTriggers()
    ) {
        self.id = id
        self.profileID = profileID
        self.isEnabled = isEnabled
        self.connectionRequirements = connectionRequirements
        self.triggers = triggers
    }

    public func requirement(for persistentID: String) -> ConnectionRequirement? {
        connectionRequirements.first { $0.persistentID == persistentID }
    }

    private enum CodingKeys: String, CodingKey { case id, profileID, isEnabled, connectionRequirements, triggers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        connectionRequirements = try container.decodeIfPresent(
            [ConnectionRequirement].self, forKey: .connectionRequirements) ?? []
        triggers = try container.decodeIfPresent(RuleTriggers.self, forKey: .triggers) ?? RuleTriggers()
    }
}

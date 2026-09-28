import Foundation

public enum KeyModifier: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case control, option, shift, command

    /// macOS menu order: ⌃ ⌥ ⇧ ⌘.
    private var order: Int {
        switch self {
        case .control: 0
        case .option: 1
        case .shift: 2
        case .command: 3
        }
    }

    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    public static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool { lhs.order < rhs.order }
}

/// A global keyboard shortcut. `keyCode` is the layout-independent virtual key code.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: Int
    /// Sorted, without duplicates.
    public private(set) var modifiers: [KeyModifier]
    /// For example "⌥⌘1".
    public var displayString: String

    public init(keyCode: Int, modifiers: [KeyModifier], displayString: String) {
        self.keyCode = keyCode
        self.modifiers = Array(Set(modifiers)).sorted()
        self.displayString = displayString
    }

    /// Builds the display string from modifiers and a key label ("1", "F5", "→").
    public init(keyCode: Int, modifiers: [KeyModifier], keyLabel: String) {
        let sorted = Array(Set(modifiers)).sorted()
        self.init(keyCode: keyCode, modifiers: sorted, displayString: sorted.map(\.symbol).joined() + keyLabel)
    }

    /// True when both shortcuts are the same key combination (display strings may differ).
    public func sameCombination(as other: KeyShortcut) -> Bool {
        keyCode == other.keyCode && Set(modifiers) == Set(other.modifiers)
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, displayString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(Int.self, forKey: .keyCode)
        let modifiers = try container.decodeIfPresent([KeyModifier].self, forKey: .modifiers) ?? []
        let display = try container.decodeIfPresent(String.self, forKey: .displayString) ?? ""
        self.init(keyCode: keyCode, modifiers: modifiers, displayString: display)
    }
}

import AppKit
import Carbon

/// Labels and menu key equivalents for virtual key codes.
enum KeyNames {
    /// Keys that have no printable character, by virtual key code.
    private static let special: [Int: (label: String, menuKey: String?)] = {
        var table: [Int: (label: String, menuKey: String?)] = [
            kVK_Return: ("↩", "\r"),
            kVK_Tab: ("⇥", "\t"),
            kVK_Space: ("Space", " "),
            kVK_Delete: ("⌫", "\u{8}"),
            kVK_ForwardDelete: ("⌦", functionKey(NSDeleteFunctionKey)),
            kVK_Escape: ("⎋", nil),
            kVK_LeftArrow: ("←", functionKey(NSLeftArrowFunctionKey)),
            kVK_RightArrow: ("→", functionKey(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", functionKey(NSUpArrowFunctionKey)),
            kVK_DownArrow: ("↓", functionKey(NSDownArrowFunctionKey)),
            kVK_Home: ("↖", functionKey(NSHomeFunctionKey)),
            kVK_End: ("↘", functionKey(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", functionKey(NSPageUpFunctionKey)),
            kVK_PageDown: ("⇟", functionKey(NSPageDownFunctionKey)),
        ]
        let functionKeys: [(Int, Int)] = [
            (kVK_F1, NSF1FunctionKey), (kVK_F2, NSF2FunctionKey), (kVK_F3, NSF3FunctionKey), (kVK_F4, NSF4FunctionKey),
            (kVK_F5, NSF5FunctionKey), (kVK_F6, NSF6FunctionKey), (kVK_F7, NSF7FunctionKey), (kVK_F8, NSF8FunctionKey),
            (kVK_F9, NSF9FunctionKey), (kVK_F10, NSF10FunctionKey), (kVK_F11, NSF11FunctionKey), (kVK_F12, NSF12FunctionKey),
            (kVK_F13, NSF13FunctionKey), (kVK_F14, NSF14FunctionKey), (kVK_F15, NSF15FunctionKey), (kVK_F16, NSF16FunctionKey),
            (kVK_F17, NSF17FunctionKey), (kVK_F18, NSF18FunctionKey), (kVK_F19, NSF19FunctionKey), (kVK_F20, NSF20FunctionKey),
        ]
        for (index, entry) in functionKeys.enumerated() {
            table[entry.0] = ("F\(index + 1)", functionKey(entry.1))
        }
        return table
    }()

    private static func functionKey(_ value: Int) -> String? {
        UnicodeScalar(value).map { String(Character($0)) }
    }

    /// Label for a key press, for example "1", "A", "F5" or "→".
    static func label(keyCode: Int, characters: String?) -> String? {
        if let entry = special[keyCode] { return entry.label }
        guard let characters = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return characters.uppercased()
    }

    /// Whether the key can be used without any modifier restrictions beyond the validator's.
    static func isModifierKey(_ keyCode: Int) -> Bool {
        [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
         kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function].contains(keyCode)
    }

    /// A menu key equivalent for display, derived from the key code or the stored label.
    static func menuKeyEquivalent(forKeyCode keyCode: Int, displayString: String) -> String? {
        if let entry = special[keyCode] { return entry.menuKey }
        let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        let label = String(displayString.drop { modifierSymbols.contains($0) })
        guard label.count == 1 else { return nil }
        return label.lowercased()
    }
}

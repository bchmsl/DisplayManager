import AppKit
import DisplayManagerCore

/// "Save Current Layout…": a summary of the displays, a name field and the auto-apply checkbox.
@MainActor
enum SaveLayoutPrompt {
    struct Answer {
        var name: String
        var createRule: Bool
    }

    /// One line per display, for example "Mi Monitor – 3008 × 1692 @ 60 Hz – USB-C Port 3".
    static func summaryLines(for snapshot: SystemSnapshot, model: AppModel) -> [String] {
        let configuration = snapshot.configuration ?? []
        return snapshot.displays.map { display in
            let screen = configuration.first { screen in
                screen.displayIDs.contains { $0.caseInsensitiveCompare(display.persistentID) == .orderedSame }
            }
            var parts = [display.name]
            if let screen, !screen.enabled {
                parts.append("Off")
            } else if let screen, let size = screen.resolution {
                var mode = "\(size.width) × \(size.height)"
                if let hz = screen.refreshRate { mode += " @ \(hz) Hz" }
                if screen.isMirrorSet { mode += " (mirrored)" }
                parts.append(mode)
            }
            parts.append(model.portLabel(for: display.connection))
            return parts.joined(separator: " – ")
        }
    }

    static func run(snapshot: SystemSnapshot, model: AppModel, suggestedName: String) -> Answer? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Save Current Layout"
        alert.informativeText = summaryLines(for: snapshot, model: model).joined(separator: "\n")
        let saveButton = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: suggestedName)
        nameField.placeholderString = "Layout name"
        nameField.setAccessibilityLabel("Layout name")
        let checkbox = NSButton(checkboxWithTitle: "Apply automatically when connected like this", target: nil, action: nil)
        checkbox.state = .off
        checkbox.toolTip = "Creates an Auto Apply rule for these displays and their current ports."

        let nameLabel = NSTextField(labelWithString: "Name:")
        let row = NSStackView(views: [nameLabel, nameField])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [row, checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 56)
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack

        let validator = NameFieldValidator(button: saveButton)
        nameField.delegate = validator
        validator.update(nameField.stringValue)
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        withExtendedLifetime(validator) {}
        guard response == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Answer(name: name, createRule: checkbox.state == .on)
    }

    /// Asks before replacing an existing layout with the same name.
    static func confirmReplace(name: String) -> Bool {
        Alerts.confirm(
            "Replace “\(name)”?",
            message: "A layout with this name already exists. Its display settings will be replaced. Its keyboard shortcut and Auto Apply rule are kept.",
            confirmTitle: "Replace")
    }
}

/// Disables Save while the name is empty.
@MainActor
private final class NameFieldValidator: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
    }

    func update(_ text: String) {
        button?.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        update(field.stringValue)
    }
}

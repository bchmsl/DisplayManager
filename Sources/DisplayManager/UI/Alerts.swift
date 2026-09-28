import AppKit
import DisplayManagerCore

/// Modal alerts. The app is an accessory app, so every alert activates it first.
@MainActor
enum Alerts {
    static func showError(_ title: String, message: String, details: String? = nil) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let details, !details.isEmpty {
            alert.addButton(withTitle: "Show Details…")
        }
        if alert.runModal() == .alertSecondButtonReturn, let details {
            showDetails(title: title, text: details)
        }
    }

    static func showError(_ error: DisplayManagerError, title: String) {
        showError(title, message: error.userMessage, details: error.diagnosticDetail)
    }

    static func showApplyFailure(_ record: ApplyStatusRecord) {
        showError(
            "Couldn't apply “\(record.profileName)”",
            message: record.failure?.message ?? record.summary,
            details: record.detailsText)
    }

    /// A scrollable, selectable monospaced text with a Copy button.
    static func showDetails(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Technical details. Copy them when reporting a problem."
        alert.accessoryView = makeTextView(text)
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Copy")
        if alert.runModal() == .alertSecondButtonReturn {
            copyToPasteboard(text)
        }
    }

    /// Returns true when the user confirms.
    static func confirm(_ title: String, message: String, confirmTitle: String, destructive: Bool = false) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .informational
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showInfo(_ title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func makeTextView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.string = text
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }
}

import AppKit
import Carbon
import DisplayManagerCore
import SwiftUI

/// Records a global shortcut for a profile. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let model: AppModel
    let profileID: UUID
    @State private var problem: ShortcutProblem?

    private var shortcut: KeyShortcut? { model.profile(id: profileID)?.shortcut }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RecorderField(
                    shortcut: shortcut,
                    onStart: {
                        problem = nil
                        model.beginShortcutRecording()
                    },
                    onRecord: { recorded in
                        problem = model.setShortcut(recorded, for: profileID)
                        model.endShortcutRecording()
                    },
                    onClear: {
                        problem = model.setShortcut(nil, for: profileID)
                        model.endShortcutRecording()
                    },
                    onCancel: { model.endShortcutRecording() })
                    .frame(width: 190, height: 24)
                Button("Clear") { problem = model.setShortcut(nil, for: profileID) }
                    .disabled(shortcut == nil)
            }
            if let message = problem?.description ?? model.shortcutProblems[profileID]?.description {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Click the field and press the keys. macOS and other apps' registered shortcuts are checked; apps that watch keys in other ways cannot be detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { model.endShortcutRecording() }
    }
}

private struct RecorderField: NSViewRepresentable {
    let shortcut: KeyShortcut?
    let onStart: () -> Void
    let onRecord: (KeyShortcut) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        update(view)
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        update(view)
    }

    private func update(_ view: RecorderNSView) {
        view.shortcut = shortcut
        view.onStart = onStart
        view.onRecord = onRecord
        view.onClear = onClear
        view.onCancel = onCancel
    }
}

final class RecorderNSView: NSView {
    var shortcut: KeyShortcut? { didSet { if oldValue != shortcut { refresh() } } }
    var onStart: () -> Void = {}
    var onRecord: (KeyShortcut) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onCancel: () -> Void = {}

    private var isRecording = false
    private var liveModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        liveModifiers = []
        onStart()
        refresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            onCancel()
        }
        refresh()
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘ combinations arrive here before keyDown. Capture them while recording.
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        liveModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        refresh()
    }

    private func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags.isEmpty, keyCode == kVK_Escape {
            finish { onCancel() }
            return
        }
        if flags.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            finish { onClear() }
            return
        }
        guard !KeyNames.isModifierKey(keyCode),
              let label = KeyNames.label(keyCode: keyCode, characters: event.characters(byApplyingModifiers: []))
        else {
            NSSound.beep()
            return
        }
        var modifiers: [KeyModifier] = []
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.command) { modifiers.append(.command) }
        let recorded = KeyShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
        finish { onRecord(recorded) }
    }

    /// Ends recording without calling `onCancel`, then runs the result callback.
    private func finish(_ result: () -> Void) {
        isRecording = false
        window?.makeFirstResponder(nil)
        result()
        refresh()
    }

    private var displayText: String {
        if isRecording {
            let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { liveModifiers.contains($0.0) }.map(\.1).joined()
            return symbols.isEmpty ? "Type shortcut…" : symbols
        }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    private func refresh() {
        needsDisplay = true
        toolTip = isRecording ? "Press a key combination. Esc cancels, Delete clears." : "Click to record a shortcut"
        setAccessibilityLabel("Keyboard shortcut")
        setAccessibilityValue(shortcut?.displayString ?? "None")
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let color: NSColor = shortcut == nil && !isRecording ? .secondaryLabelColor : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: displayText, attributes: attributes)
        let height = text.size().height
        text.draw(in: NSRect(x: 6, y: (bounds.height - height) / 2, width: bounds.width - 12, height: height))
    }
}

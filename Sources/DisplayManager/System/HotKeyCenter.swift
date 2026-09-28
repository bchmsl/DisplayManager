import AppKit
import Carbon
import DisplayManagerCore

/// Global shortcuts through Carbon `RegisterEventHotKey`. Needs no Accessibility permission.
///
/// Shortcuts are registered non-exclusively, so this app never blocks another app's hotkey.
/// Conflict checks (verified on macOS 27):
/// - macOS shortcuts come from `CopySymbolicHotKeys` (Carbon modifier bits).
/// - An exclusive probe detects shortcuts that another app registered exclusively. Non-exclusive
///   registrations by other apps and event-tap based shortcuts cannot be detected.
@MainActor
final class HotKeyCenter {
    nonisolated static let signature: OSType = 0x444D_4752 // "DMGR"

    var onHotKey: ((UUID) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (profileID: UUID, ref: EventHotKeyRef)] = [:]
    private var desired: [(profileID: UUID, shortcut: KeyShortcut)] = []
    private var nextID: UInt32 = 1
    private(set) var isSuspended = false
    private let sink = HotKeySink()

    init() {
        sink.handler = { [weak self] id in self?.handlePress(id: id) }
    }

    /// Installs the Carbon event handler once.
    func install() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec,
            Unmanaged.passUnretained(sink).toOpaque(), &handlerRef)
        if status != noErr {
            Log.error(.hotkeys, "Installing the hotkey handler failed (\(status))")
        }
    }

    /// Replaces the registered shortcuts. Returns the profiles whose shortcut macOS refused.
    @discardableResult
    func update(_ shortcuts: [(profileID: UUID, shortcut: KeyShortcut)]) -> [UUID: ShortcutProblem] {
        desired = shortcuts
        guard !isSuspended else { return [:] }
        return registerDesired()
    }

    /// Unregisters every shortcut while the recorder is active, so an existing one can be recorded again.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        registerDesired()
    }

    /// System and other-app conflicts. Call while suspended so this app's own registrations do not interfere.
    func availabilityProblem(for shortcut: KeyShortcut) -> ShortcutProblem? {
        if Self.isSystemShortcut(shortcut) { return .usedBySystem }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: 0), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return .usedByAnotherApp
        default: return .registrationFailed(status: status)
        }
    }

    // MARK: Registration

    @discardableResult
    private func registerDesired() -> [UUID: ShortcutProblem] {
        unregisterAll()
        var problems: [UUID: ShortcutProblem] = [:]
        for (profileID, shortcut) in desired {
            let id = nextID
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers),
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
                OptionBits(0), &ref)
            if status == noErr, let ref {
                registrations[id] = (profileID, ref)
            } else {
                problems[profileID] = .registrationFailed(status: status)
                Log.warning(.hotkeys, "Registering shortcut \(shortcut.displayString) failed (\(status))")
            }
        }
        if !desired.isEmpty {
            Log.info(.hotkeys, "Registered \(registrations.count) of \(desired.count) shortcuts")
        }
        return problems
    }

    private func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func handlePress(id: UInt32) {
        guard !isSuspended, let registration = registrations[id] else { return }
        onHotKey?(registration.profileID)
    }

    // MARK: Modifiers and system shortcuts

    static let carbonModifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    static func carbonModifiers(_ modifiers: [KeyModifier]) -> UInt32 {
        modifiers.reduce(UInt32(0)) { result, modifier in
            switch modifier {
            case .command: result | UInt32(cmdKey)
            case .option: result | UInt32(optionKey)
            case .shift: result | UInt32(shiftKey)
            case .control: result | UInt32(controlKey)
            }
        }
    }

    /// True when an enabled macOS shortcut (Spotlight, Mission Control, screenshots, …) uses the combination.
    static func isSystemShortcut(_ shortcut: KeyShortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let items = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        let wanted = carbonModifiers(shortcut.modifiers)
        return items.contains { item in
            guard (item["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (item["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue,
                  let modifiers = (item["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value
            else { return false }
            return code == shortcut.keyCode && (modifiers & carbonModifierMask) == wanted
        }
    }
}

/// Bridges the Carbon C callback to the main actor.
@MainActor
private final class HotKeySink {
    var handler: ((UInt32) -> Void)?

    nonisolated func send(_ id: UInt32) {
        Task { @MainActor in self.handler?(id) }
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    Unmanaged<HotKeySink>.fromOpaque(userData).takeUnretainedValue().send(hotKeyID.id)
    return noErr
}

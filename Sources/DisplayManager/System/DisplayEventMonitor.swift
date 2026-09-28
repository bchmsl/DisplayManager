import AppKit
import CoreGraphics
import DisplayManagerCore
import IOKit

/// Display, sleep/wake and session events, delivered on the main actor.
enum DisplayEvent: Sendable, CustomStringConvertible {
    /// A display was added, removed, enabled or disabled (CoreGraphics), or a port transport appeared or went away (IOKit).
    case topologyChanged(source: String)
    /// Mode, origin, rotation or mirroring changed.
    case layoutChanged
    case willSleep
    case didWake
    case sessionResignedActive
    case sessionBecameActive

    var description: String {
        switch self {
        case .topologyChanged(let source): "topology changed (\(source))"
        case .layoutChanged: "layout changed"
        case .willSleep: "will sleep"
        case .didWake: "did wake"
        case .sessionResignedActive: "session resigned active"
        case .sessionBecameActive: "session became active"
        }
    }
}

/// Watches CoreGraphics reconfiguration, IOKit DisplayPort transports and NSWorkspace notifications.
///
/// C callbacks get an unretained pointer to a small sink object and hop to the main actor with a Task.
@MainActor
final class DisplayEventMonitor {
    private let sink = DisplayEventSink()
    private var cgCallbackRegistered = false
    private var notificationPort: IONotificationPortRef?
    private var ioIterators: [io_iterator_t] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(handler: @escaping @MainActor (DisplayEvent) -> Void) {
        sink.handler = handler
    }

    func start() {
        startCoreGraphics()
        startIOKit()
        startWorkspaceNotifications()
    }

    func stop() {
        if cgCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(sink).toOpaque())
            cgCallbackRegistered = false
        }
        for iterator in ioIterators { IOObjectRelease(iterator) }
        ioIterators.removeAll()
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: CoreGraphics

    private func startCoreGraphics() {
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(sink).toOpaque())
        cgCallbackRegistered = result == .success
        if !cgCallbackRegistered {
            Log.error(.displays, "Registering the display reconfiguration callback failed (\(result.rawValue))")
        }
    }

    // MARK: IOKit

    private func startIOKit() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.warning(.topology, "IOKit notifications are not available")
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notificationPort = port
        let context = Unmanaged.passUnretained(sink).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            guard let matching = IOServiceMatching(PortTopologyReader.transportClass) else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, matching, transportNotificationCallback, context, &iterator)
            guard result == KERN_SUCCESS else {
                Log.warning(.topology, "IOKit transport notification failed (\(result))")
                continue
            }
            // Arms the notification. Existing services are not events.
            DisplayEventSink.drain(iterator)
            ioIterators.append(iterator)
        }
    }

    // MARK: NSWorkspace

    private func startWorkspaceNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        let mapping: [(Notification.Name, DisplayEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidWakeNotification, .didWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
        ]
        for (name, event) in mapping {
            let sink = sink
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { _ in sink.send(event) }
            observers.append((workspace, observer))
        }
        let sink = sink
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in sink.send(.layoutChanged) }
        observers.append((NotificationCenter.default, screens))
    }
}

/// Receives C callbacks and forwards them to the main actor.
@MainActor
private final class DisplayEventSink {
    var handler: ((DisplayEvent) -> Void)?

    nonisolated func send(_ event: DisplayEvent) {
        Task { @MainActor in self.handler?(event) }
    }

    nonisolated static func drain(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            IOObjectRelease(service)
        }
    }
}

private let topologyFlags: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    // Callbacks arrive in begin/end pairs. Only the end of a reconfiguration counts.
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    let sink = Unmanaged<DisplayEventSink>.fromOpaque(userInfo).takeUnretainedValue()
    sink.send(flags.isDisjoint(with: topologyFlags) ? .layoutChanged : .topologyChanged(source: "CoreGraphics"))
}

private let transportNotificationCallback: IOServiceMatchingCallback = { refcon, iterator in
    DisplayEventSink.drain(iterator)
    guard let refcon else { return }
    Unmanaged<DisplayEventSink>.fromOpaque(refcon).takeUnretainedValue().send(.topologyChanged(source: "IOKit"))
}

import Foundation
@testable import DisplayManagerCore

enum TestIDs {
    static let builtIn = "AAAAAAAA-1111-2222-3333-444444444444"
    static let external = "BBBBBBBB-5555-6666-7777-888888888888"
    static let third = "CCCCCCCC-9999-AAAA-BBBB-CCCCCCCCCCCC"
    static let host = "Mac16,8"
}

struct FixtureMissing: Error {
    var name: String
}

func fixtureData(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: name)
    guard let fileURL = Bundle.module.url(
        forResource: url.deletingPathExtension().lastPathComponent,
        withExtension: url.pathExtension,
        subdirectory: "Fixtures"
    ) else { throw FixtureMissing(name: name) }
    return try Data(contentsOf: fileURL)
}

func fixture(_ name: String) throws -> String {
    String(decoding: try fixtureData(name), as: UTF8.self)
}

func usbC(_ number: Int, host: String = TestIDs.host, tunneled: Bool = false) -> ConnectionFingerprint {
    ConnectionFingerprint(hostModel: host, portType: .usbC, portNumber: number, tunneled: tunneled)
}

extension LiveDisplay {
    static func builtIn(id: String = TestIDs.builtIn, enabled: Bool = true) -> LiveDisplay {
        LiveDisplay(
            persistentID: id, contextualID: 1, serialID: "s1000000001",
            vendorID: 0x0610, productID: 0xA061, serialNumber: 1_000_000_001,
            name: "Built-in Retina Display", typeDescription: "MacBook built in screen",
            isBuiltIn: true, isEnabled: enabled, connection: .builtIn)
    }

    static func external(
        id: String = TestIDs.external,
        name: String = "Mi Monitor",
        connection: ConnectionState = .external(usbC(3)),
        vendor: Int = 0x61A9,
        product: Int = 0x27A1,
        serial: Int = 2_000_000_002
    ) -> LiveDisplay {
        LiveDisplay(
            persistentID: id, contextualID: 3, serialID: "s\(serial)",
            vendorID: vendor, productID: product, serialNumber: serial,
            name: name, typeDescription: "27 inch external screen",
            isBuiltIn: false, connection: connection)
    }
}

func screen(
    _ id: String,
    res: (Int, Int),
    hz: Int? = 60,
    origin: (Int, Int),
    rotation: Int = 0,
    scaling: Bool = true
) -> ScreenSetting {
    ScreenSetting(
        displayIDs: [id], enabled: true,
        resolution: DisplaySize(width: res.0, height: res.1),
        refreshRate: hz, colorDepth: 8, scaling: scaling,
        origin: DisplayPoint(x: origin.0, y: origin.1), rotation: rotation)
}

func disabledScreen(_ id: String) -> ScreenSetting {
    ScreenSetting(displayIDs: [id], enabled: false)
}

func makeSnapshot(displays: [LiveDisplay], configuration: [ScreenSetting]?, date: Date = Date(timeIntervalSince1970: 0)) -> SystemSnapshot {
    SystemSnapshot(
        displays: displays,
        parsedList: configuration.map { ParsedList(screens: [], configuration: $0, commandLine: "") },
        topologyStatus: .available,
        hostModel: TestIDs.host,
        capturedAt: date)
}

/// The user's example: external 3008x1692@60 main at (0,0), built-in 1512x982@120 at (3008,608).
func deskProfile(id: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111") ?? UUID()) -> LayoutProfile {
    LayoutProfile(
        id: id, name: "Desk",
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
        screens: [
            screen(TestIDs.external, res: (3008, 1692), hz: 60, origin: (0, 0)),
            screen(TestIDs.builtIn, res: (1512, 982), hz: 120, origin: (3008, 608)),
        ],
        displays: [LiveDisplay.external().displayInfo, LiveDisplay.builtIn().displayInfo])
}

func macBookOnlyProfile(id: UUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222") ?? UUID()) -> LayoutProfile {
    LayoutProfile(
        id: id, name: "MacBook Only",
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
        screens: [screen(TestIDs.builtIn, res: (1800, 1169), hz: 120, origin: (0, 0))],
        displays: [LiveDisplay.builtIn().displayInfo])
}

/// Current configuration that matches `deskProfile()`.
var deskConfiguration: [ScreenSetting] { deskProfile().screens }

/// The configuration from the real fixture (external above-left of the built-in).
var fixtureConfiguration: [ScreenSetting] {
    [
        screen(TestIDs.builtIn, res: (1800, 1169), hz: 120, origin: (0, 0)),
        screen(TestIDs.external, res: (3008, 1692), hz: 60, origin: (-592, -1692)),
    ]
}

/// Scriptable DisplayControl. Snapshots in `queue` are returned first; afterwards `current` is returned.
/// Each run pops the next scripted result and, when it carries a snapshot, makes it current.
actor FakeDisplayControl: DisplayControl {
    struct RunResult {
        var output: ProcessOutput
        var resultingSnapshot: SystemSnapshot?
    }

    var current: SystemSnapshot
    var queue: [SystemSnapshot]
    var runResults: [RunResult]
    var snapshotError: DisplayManagerError?
    private(set) var runArguments: [[String]] = []
    private(set) var snapshotCount = 0

    init(current: SystemSnapshot, queue: [SystemSnapshot] = [], runResults: [RunResult] = [], snapshotError: DisplayManagerError? = nil) {
        self.current = current
        self.queue = queue
        self.runResults = runResults
        self.snapshotError = snapshotError
    }

    func captureSnapshot() async throws -> SystemSnapshot {
        snapshotCount += 1
        if let snapshotError { throw snapshotError }
        if !queue.isEmpty { return queue.removeFirst() }
        return current
    }

    func runDisplayplacer(arguments: [String]) async throws -> ProcessOutput {
        runArguments.append(arguments)
        guard !runResults.isEmpty else {
            return ProcessOutput(exitCode: 0, stdout: "", stderr: "", duration: 0.05, timedOut: false)
        }
        let result = runResults.removeFirst()
        if let snapshot = result.resultingSnapshot { current = snapshot }
        return result.output
    }

    nonisolated var executablePathForDisplay: String? { "/opt/homebrew/bin/displayplacer" }
}

actor RecordingSleeper: Sleeper {
    private(set) var delays: [Double] = []

    func sleep(seconds: Double) async throws {
        delays.append(seconds)
    }
}

func output(exit: Int32 = 0, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessOutput {
    ProcessOutput(exitCode: exit, stdout: stdout, stderr: stderr, duration: 0.05, timedOut: timedOut)
}

/// Decodes a hex string ("00ff…") into bytes.
func hexData(_ hex: String) -> Data {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
        if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
        index = next
    }
    return Data(bytes)
}

/// EDID of the external test monitor, with an anonymized serial and serial string.
/// XMI (vendor 25001), product 10145, serial 2000000002, name "Mi Monitor", valid checksum.
let externalMonitorEDID = hexData(
    "00ffffffffffff0061a9a1270294357715230104b53c22783a6f31ac5241ac260d5054210800b30081c0810081809500a9c00101010108e80030f2705a80b0588a0055502100001e000000fd00183e1e8c3c000a202020202020000000fc004d69204d6f6e69746f720a2020000000ff00414e4f4e594d495a45440a202001cc")

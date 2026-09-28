import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct EDIDTests {
    @Test func parsesIdentityFields() throws {
        #expect(externalMonitorEDID.count == 128)
        let info = try #require(EDIDInfo.parse(externalMonitorEDID))
        #expect(info.vendorCode == 0x61A9)
        #expect(info.manufacturerID == "XMI")
        #expect(info.productCode == 10145)
        #expect(info.serialNumber == 2_000_000_002)
        #expect(info.displayName == "Mi Monitor")
    }

    @Test func toleratesWrongChecksum() throws {
        var data = externalMonitorEDID
        data[127] = data[127] &+ 1
        #expect(EDIDInfo.parse(data)?.displayName == "Mi Monitor")
    }

    @Test func rejectsShortOrHeaderlessData() {
        #expect(EDIDInfo.parse(externalMonitorEDID.prefix(127)) == nil)
        var data = externalMonitorEDID
        data[0] = 0x01
        #expect(EDIDInfo.parse(data) == nil)
        #expect(EDIDInfo.parse(Data()) == nil)
    }

    @Test func missingNameDescriptorGivesNil() throws {
        var data = externalMonitorEDID
        // Turn the 0xFC name descriptor (third descriptor, offset 90) into a dummy descriptor.
        data[90 + 3] = 0x10
        #expect(try #require(EDIDInfo.parse(data)).displayName == nil)
    }
}

@Suite struct ConnectionFingerprintTests {
    @Test func keysAreStableAndIncludeHostAndTunnel() {
        #expect(usbC(3).key == "Mac16,8/usbc@3")
        #expect(usbC(1, tunneled: true).key == "Mac16,8/usbc@1/tunnel")
        #expect(ConnectionFingerprint(hostModel: "Mac15,3", portType: .hdmi, portNumber: 1, tunneled: false).key == "Mac15,3/hdmi@1")
        #expect(ConnectionFingerprint(hostModel: "M", portType: .other(9), portNumber: 2, tunneled: false).key == "M/type9@2")
    }

    @Test func equalityUsesKey() {
        #expect(usbC(3) == usbC(3))
        #expect(usbC(3) != usbC(1))
        #expect(usbC(3) != usbC(3, host: "Mac15,3"))
        #expect(usbC(3) != usbC(3, tunneled: true))
    }

    @Test func technicalLabelsNeverInventPositions() {
        #expect(usbC(3).technicalLabel == "USB-C Port 3")
        #expect(usbC(1, tunneled: true).technicalLabel == "USB-C Port 1 (Thunderbolt)")
        #expect(ConnectionFingerprint(hostModel: "M", portType: .hdmi, portNumber: 1, tunneled: false).technicalLabel == "HDMI Port")
        #expect(ConnectionFingerprint(hostModel: "M", portType: .hdmi, portNumber: 2, tunneled: false).technicalLabel == "HDMI Port 2")
        #expect(ConnectionFingerprint(hostModel: "M", portType: .other(7), portNumber: 4, tunneled: false).technicalLabel == "Port 4 (type 7)")
        for label in [usbC(1).technicalLabel, usbC(2).technicalLabel, usbC(3).technicalLabel] {
            #expect(!label.lowercased().contains("left") && !label.lowercased().contains("right"))
        }
    }

    @Test func portKindMapsIORegistryValues() {
        #expect(PortKind(ioRegistryValue: 2) == .usbC)
        #expect(PortKind(ioRegistryValue: 6) == .hdmi)
        #expect(PortKind(ioRegistryValue: 11) == .other(11))
    }

    @Test func portKindCodingRoundTrips() throws {
        for kind in [PortKind.usbC, .hdmi, .other(12)] {
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(PortKind.self, from: data) == kind)
        }
        #expect(String(decoding: try JSONEncoder().encode(PortKind.usbC), as: UTF8.self) == "\"usbC\"")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PortKind.self, from: Data("\"thunderbolt\"".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PortKind.self, from: Data("\"other-99999\"".utf8)) }
    }

    @Test func knownPortLabels() {
        let named = KnownPort(connection: usbC(3), name: "Desk Port")
        let unnamed = KnownPort(connection: usbC(1), name: "  ")
        #expect(named.displayLabel == "Desk Port (USB-C Port 3)")
        #expect(unnamed.displayLabel == "USB-C Port 1")
        #expect([named, unnamed].label(for: usbC(3)) == "Desk Port (USB-C Port 3)")
        #expect([named].label(for: usbC(2)) == "USB-C Port 2")
        #expect(named.id == usbC(3).key)
    }
}

@Suite struct PortTransportRecordTests {
    @Test func derivedPortFallbackOrder() {
        let builtInProps = PortTransportRecord(builtInPortType: 2, builtInPortNumber: 3, parentPortType: 6, parentPortNumber: 1, parentPortBuiltIn: true, ancestorPortType: 2, ancestorPortNumber: 1)
        #expect(builtInProps.derivedPort?.kind == .usbC)
        #expect(builtInProps.derivedPort?.number == 3)

        let parentProps = PortTransportRecord(parentPortType: 6, parentPortNumber: 1, parentPortBuiltIn: true, ancestorPortType: 2, ancestorPortNumber: 2)
        #expect(parentProps.derivedPort?.kind == .hdmi)
        #expect(parentProps.derivedPort?.number == 1)

        let parentNotBuiltIn = PortTransportRecord(parentPortType: 6, parentPortNumber: 1, parentPortBuiltIn: false, ancestorPortType: 2, ancestorPortNumber: 2)
        #expect(parentNotBuiltIn.derivedPort?.kind == .usbC)
        #expect(parentNotBuiltIn.derivedPort?.number == 2)

        #expect(PortTransportRecord(builtInPortType: 2).derivedPort == nil)
    }

    @Test func liveness() {
        #expect(PortTransportRecord(active: true).isLive)
        #expect(PortTransportRecord(hotPlugDetected: true).isLive)
        #expect(!PortTransportRecord().isLive)
    }
}

@Suite struct SnapshotAssemblerTests {
    let builtInCG = CGDisplayRecord(
        displayID: 1, uuid: TestIDs.builtIn, isBuiltIn: true, isMain: true,
        vendorNumber: 0x0610, modelNumber: 0xA061, serialNumber: 1_000_000_001,
        bounds: DisplayRect(x: 0, y: 0, width: 1800, height: 1169), rotation: 0, localizedName: "Built-in Retina Display")
    let externalCG = CGDisplayRecord(
        displayID: 3, uuid: TestIDs.external, isBuiltIn: false, isMain: false,
        vendorNumber: 0x61A9, modelNumber: 10145, serialNumber: 2_000_000_002,
        bounds: DisplayRect(x: -592, y: -1692, width: 3008, height: 1692), rotation: 0, localizedName: nil)

    func transport(port: Int = 3, type: Int = 2, live: Bool = true, edid: Data? = externalMonitorEDID, tunneled: Bool = false) -> PortTransportRecord {
        PortTransportRecord(
            transportDescription: "Port-USB-C@\(port)/DisplayPort",
            builtInPortType: type, builtInPortNumber: port,
            tunneled: tunneled, active: live, hotPlugDetected: live, edid: edid)
    }

    func assemble(cg: [CGDisplayRecord], transports: [PortTransportRecord], status: TopologyStatus = .available, list: ParsedList? = nil) -> SystemSnapshot {
        SnapshotAssembler.assemble(
            cgDisplays: cg, transports: transports, topologyStatus: status,
            parsedList: list, hostModel: TestIDs.host, capturedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func joinsEDIDToPort() throws {
        let snapshot = assemble(cg: [builtInCG, externalCG], transports: [transport(port: 1, live: false), transport(port: 3)])
        let external = try #require(snapshot.display(persistentID: TestIDs.external))
        #expect(external.connection == .external(usbC(3)))
        #expect(external.name == "Mi Monitor")
        #expect(external.manufacturerID == "XMI")
        #expect(external.transportDescription == "Port-USB-C@3/DisplayPort")
        #expect(snapshot.display(persistentID: TestIDs.builtIn)?.connection == .builtIn)
        #expect(snapshot.signature.entries.map(\.connectionKey).sorted() == ["Mac16,8/usbc@3", "builtin"])
    }

    @Test func tunneledAndHDMIPorts() throws {
        let tunneled = assemble(cg: [externalCG], transports: [transport(port: 1, tunneled: true)])
        #expect(tunneled.displays.first?.connection == .external(usbC(1, tunneled: true)))
        let hdmi = assemble(cg: [externalCG], transports: [transport(port: 1, type: 6)])
        #expect(hdmi.displays.first?.connection.fingerprint?.portType == .hdmi)
    }

    @Test func unpluggedTransportsAreIgnored() {
        let snapshot = assemble(cg: [externalCG], transports: [transport(live: false)])
        #expect(snapshot.displays.first?.connection == .unidentified(.noTransport))
    }

    @Test func identicalMonitorsAreAmbiguous() {
        var twin = externalCG
        twin.displayID = 4
        twin.uuid = TestIDs.third
        let snapshot = assemble(cg: [externalCG, twin], transports: [transport(port: 1), transport(port: 3)])
        #expect(snapshot.displays.allSatisfy { $0.connection == .unidentified(.ambiguous) })
    }

    @Test func missingPortPropertiesAreReported() {
        let record = PortTransportRecord(active: true, edid: externalMonitorEDID)
        let snapshot = assemble(cg: [externalCG], transports: [record])
        #expect(snapshot.displays.first?.connection == .unidentified(.noPortInfo))
    }

    @Test func unavailableTopologyMarksExternalDisplays() {
        let snapshot = assemble(cg: [builtInCG, externalCG], transports: [], status: .unavailable("no IOKit"))
        #expect(snapshot.display(persistentID: TestIDs.builtIn)?.connection == .builtIn)
        #expect(snapshot.display(persistentID: TestIDs.external)?.connection == .unidentified(.topologyUnavailable))
    }

    @Test func includesParsedScreensThatAreNotOnline() throws {
        let list = try ListOutputParser.parse(fixture("list-synthetic-disabled.txt"))
        var mainExternal = externalCG
        mainExternal.isMain = true
        let snapshot = assemble(cg: [mainExternal], transports: [transport()], list: list)
        #expect(snapshot.displays.count == 2)
        let builtIn = try #require(snapshot.display(persistentID: TestIDs.builtIn))
        #expect(builtIn.isBuiltIn)
        #expect(!builtIn.isEnabled)
        #expect(builtIn.connection == .builtIn)
        #expect(builtIn.name == "Built-in Display")
        #expect(builtIn.serialID == "s1000000001")
    }

    @Test func matchesParsedScreensByUUIDCaseInsensitively() throws {
        let list = try ListOutputParser.parse(fixture("list-builtin-and-external.txt"))
        var lower = externalCG
        lower.uuid = TestIDs.external.lowercased()
        let snapshot = assemble(cg: [builtInCG, lower], transports: [transport()], list: list)
        #expect(snapshot.displays.count == 2)
        #expect(snapshot.display(persistentID: TestIDs.external)?.serialID == "s2000000002")
        #expect(snapshot.display(persistentID: TestIDs.external)?.typeDescription == "27 inch external screen")
    }

    @Test func nameFallsBackToTypeDescription() throws {
        let list = try ListOutputParser.parse(fixture("list-builtin-and-external.txt"))
        let snapshot = assemble(cg: [builtInCG, externalCG], transports: [], list: list)
        #expect(snapshot.display(persistentID: TestIDs.external)?.name == "27 inch external screen")
        #expect(snapshot.display(persistentID: TestIDs.builtIn)?.name == "Built-in Retina Display")
    }

    @Test func signatureIgnoresLayoutChanges() {
        let first = assemble(cg: [builtInCG, externalCG], transports: [transport()])
        var moved = externalCG
        moved.bounds = DisplayRect(x: 1800, y: 0, width: 1920, height: 1080)
        let second = assemble(cg: [builtInCG, moved], transports: [transport()])
        #expect(first.signature == second.signature)
        let otherPort = assemble(cg: [builtInCG, externalCG], transports: [transport(port: 1)])
        #expect(first.signature != otherPort.signature)
    }
}

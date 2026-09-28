import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct LayoutDocumentTests {
    @Test func decodesVersionOneFixture() throws {
        let document = try LayoutDocument.decode(fixtureData("layouts-v1.json"))
        #expect(document.version == 1)
        #expect(document.exportedBy == "DisplayManager 1.0.0")
        #expect(document.profiles.map(\.name) == ["Desk", "MacBook Only"])

        let desk = document.profiles[0]
        #expect(desk.id == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(desk.screens == deskProfile().screens)
        #expect(desk.createdAt == Date(timeIntervalSince1970: 1_788_256_800))
        #expect(desk.updatedAt.timeIntervalSince1970 == 1_788_343_200.5)
        #expect(desk.shortcut?.modifiers == [.option, .command])
        #expect(desk.shortcut?.keyCode == 18)
        let external = desk.displayInfo(for: TestIDs.external)
        #expect(external.connection == usbC(3))
        #expect(external.vendorID == 25001)
        #expect(external.bounds == DisplayRect(x: 0, y: 0, width: 3008, height: 1692))

        let macOnly = document.profiles[1]
        #expect(macOnly.displays.first?.isBuiltIn == true)
        #expect(macOnly.shortcut == nil)

        #expect(document.rules.count == 1)
        #expect(document.rules[0].profileID == desk.id)
        #expect(document.rules[0].connectionRequirements == [ConnectionRequirement(persistentID: TestIDs.external, connection: usbC(3))])
        #expect(document.knownPorts == [KnownPort(connection: usbC(3), name: "Desk Port")])
        #expect(ImportValidator.validate(document).isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var desk = deskProfile()
        desk.shortcut = KeyShortcut(keyCode: 18, modifiers: [.command, .option], keyLabel: "1")
        desk.sourceCommand = "displayplacer \"id:1\""
        let document = LayoutDocument(
            exportedBy: "DisplayManager test",
            profiles: [desk, macBookOnlyProfile()],
            rules: [AutoApplyRule(profileID: desk.id, connectionRequirements: [ConnectionRequirement(persistentID: TestIDs.external, connection: usbC(1, tunneled: true))])],
            knownPorts: [KnownPort(connection: ConnectionFingerprint(hostModel: "Mac16,8", portType: .other(9), portNumber: 2, tunneled: false), name: "Dock")])
        let data = try document.encoded()
        #expect(try LayoutDocument.decode(data) == document)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"portType\" : \"usbC\""))
        #expect(text.contains("\"other-9\""))
        #expect(text.contains("\"createdAt\" : \"1970-01-01T00:00:00Z\""))
    }

    @Test func minimalProfilesGetDefaults() throws {
        let json = """
        {"version": 1, "profiles": [{"id": "44444444-4444-4444-8444-444444444444", "name": "Bare",
          "screens": [{"displayIDs": ["AAAAAAAA-1111-2222-3333-444444444444"]}]}],
         "rules": [{"id": "66666666-6666-4666-8666-666666666666", "profileID": "44444444-4444-4444-8444-444444444444"}]}
        """
        let document = try LayoutDocument.decode(Data(json.utf8))
        let profile = try #require(document.profiles.first)
        #expect(profile.displays.isEmpty)
        #expect(profile.screens[0].enabled)
        #expect(profile.screens[0].extraArguments.isEmpty)
        #expect(profile.displayInfo(for: TestIDs.builtIn).name == "Display AAAAAAAA")
        #expect(document.rules[0].isEnabled)
        #expect(document.rules[0].triggers == RuleTriggers())
        #expect(document.knownPorts.isEmpty)
    }

    @Test func refusesNewerVersions() throws {
        #expect(throws: DisplayManagerError.newerDocumentVersion(99)) {
            try LayoutDocument.decode(fixtureData("invalid-newer-version.json"))
        }
    }

    @Test func refusesMissingOrOldVersions() throws {
        #expect(throws: DisplayManagerError.invalidDocument("Missing \"version\".")) {
            try LayoutDocument.decode(fixtureData("invalid-not-a-document.json"))
        }
        #expect(throws: DisplayManagerError.unsupportedDocumentVersion(0)) {
            try LayoutDocument.decode(Data(#"{"version": 0}"#.utf8))
        }
    }

    @Test(arguments: ["", "not json", "[]", #"{"version": "1"}"#])
    func refusesGarbage(_ text: String) {
        #expect(throws: DisplayManagerError.self) { try LayoutDocument.decode(Data(text.utf8)) }
    }

    @Test func describesWhereDecodingFailed() {
        let json = #"{"version": 1, "profiles": [{"id": "44444444-4444-4444-8444-444444444444", "name": "X", "screens": [{"displayIDs": "oops"}]}]}"#
        do {
            _ = try LayoutDocument.decode(Data(json.utf8))
            Issue.record("expected an error")
        } catch let DisplayManagerError.invalidDocument(detail) {
            #expect(detail.hasPrefix("profiles.[0].screens.[0].displayIDs") || detail.contains("displayIDs"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func invalidDatesAreRejected() {
        let json = #"{"version": 1, "profiles": [{"id": "44444444-4444-4444-8444-444444444444", "name": "X", "createdAt": "yesterday", "screens": []}]}"#
        #expect(throws: DisplayManagerError.self) { try LayoutDocument.decode(Data(json.utf8)) }
    }
}

@Suite struct ImportValidatorTests {
    @Test func unsafeFixtureIsRejectedWithReasons() throws {
        let document = try LayoutDocument.decode(fixtureData("invalid-unsafe-values.json"))
        let issues = ImportValidator.validate(document).map(\.description)
        #expect(issues.contains { $0.hasPrefix("“Injected”:") && $0.contains("not allowed") })
        #expect(issues.contains("Layout 2: name must be 1–100 characters"))
        #expect(issues.contains("Layout 2: resolution 0x99999 is out of range"))
        #expect(issues.contains("Layout 2: refresh rate 5000 is out of range"))
        #expect(issues.contains("Layout 2: rotation 45 is not 0, 90, 180 or 270"))
        #expect(issues.contains("Layout 2: exactly one display that is on must be at position (0,0)"))
        #expect(issues.contains("Rule 1: refers to a layout that is not in the file"))
    }

    @Test func unsafeExtraArgumentsAreRejected() {
        var profile = deskProfile()
        profile.screens[0].extraArguments = ["quiet": "$(id)"]
        #expect(!ImportValidator.validate(LayoutDocument(profiles: [profile])).isEmpty)
        profile.screens[0].extraArguments = ["origin": "(5,5)"]
        #expect(!ImportValidator.validate(LayoutDocument(profiles: [profile])).isEmpty)
        profile.screens[0].extraArguments = ["mode": "12"]
        #expect(ImportValidator.validate(LayoutDocument(profiles: [profile])).isEmpty)
    }

    @Test func structuralProblems() {
        var noScreens = deskProfile()
        noScreens.screens = []
        #expect(ImportValidator.validate(LayoutDocument(profiles: [noScreens])).map(\.message) == ["no screens"])

        var allOff = deskProfile()
        allOff.screens = [disabledScreen(TestIDs.external)]
        #expect(ImportValidator.validate(LayoutDocument(profiles: [allOff])).map(\.message) == ["at least one display must be on"])

        var duplicateIDs = deskProfile()
        duplicateIDs.screens[1].displayIDs = [TestIDs.external.lowercased()]
        #expect(ImportValidator.validate(LayoutDocument(profiles: [duplicateIDs])).contains { $0.message.contains("used more than once") })

        var noOrigin = deskProfile()
        noOrigin.screens[1].origin = nil
        #expect(ImportValidator.validate(LayoutDocument(profiles: [noOrigin])).map(\.message) == ["a display that is on has no position"])

        // One enabled display without a position is allowed (displayplacer keeps it main).
        var single = macBookOnlyProfile()
        single.screens[0].origin = nil
        #expect(ImportValidator.validate(LayoutDocument(profiles: [single])).isEmpty)

        let twice = deskProfile()
        #expect(ImportValidator.validate(LayoutDocument(profiles: [twice, twice])).map(\.message).contains("duplicate layout id"))
    }

    @Test func metadataAndPortProblems() {
        var profile = deskProfile()
        profile.displays[0].connection = ConnectionFingerprint(hostModel: "Mac16,8; rm", portType: .usbC, portNumber: 3, tunneled: false)
        profile.displays[1].persistentID = "bad id"
        let rule = AutoApplyRule(
            profileID: profile.id,
            connectionRequirements: [ConnectionRequirement(persistentID: TestIDs.third, connection: usbC(99))])
        let ports = [KnownPort(connection: usbC(3), name: "A"), KnownPort(connection: usbC(3), name: "B")]
        let issues = ImportValidator.validate(LayoutDocument(profiles: [profile], rules: [rule], knownPorts: ports)).map(\.description)
        #expect(issues.contains("“Desk”: invalid Mac model in a port"))
        #expect(issues.contains("“Desk”: invalid display id"))
        #expect(issues.contains("Rule 1: port requirement refers to a display that is not in “Desk”"))
        #expect(issues.contains("Rule 1: invalid port number 99"))
        #expect(issues.contains("Learned port: USB-C Port 3 appears more than once"))
    }

    @Test func addModeKeepsExistingDataAndResolvesConflicts() {
        var existingDesk = deskProfile()
        existingDesk.shortcut = KeyShortcut(keyCode: 18, modifiers: [.option, .command], keyLabel: "1")
        let existingRule = AutoApplyRule(
            profileID: existingDesk.id,
            connectionRequirements: [ConnectionRequirement(persistentID: TestIDs.external, connection: usbC(3))])
        let existing = LayoutDocument(profiles: [existingDesk], rules: [existingRule], knownPorts: [KnownPort(connection: usbC(3), name: "Mine")])

        var importedDesk = deskProfile() // same id and name as the existing one
        importedDesk.shortcut = KeyShortcut(keyCode: 18, modifiers: [.command, .option], keyLabel: "1")
        let importedMac = macBookOnlyProfile()
        let importedRule = AutoApplyRule(
            id: existingRule.id,
            profileID: importedDesk.id,
            connectionRequirements: [ConnectionRequirement(persistentID: TestIDs.external, connection: usbC(3))])
        let imported = LayoutDocument(
            profiles: [importedDesk, importedMac], rules: [importedRule],
            knownPorts: [KnownPort(connection: usbC(3), name: "Theirs"), KnownPort(connection: usbC(1), name: "Side")])

        let (merged, summary) = ImportValidator.merge(imported, into: existing, mode: .add)
        #expect(merged.profiles.count == 3)
        #expect(merged.profiles[0] == existingDesk)
        #expect(merged.profiles.map(\.name) == ["Desk", "Desk 2", "MacBook Only"])
        #expect(merged.profiles[1].id != existingDesk.id)
        #expect(merged.profiles[1].shortcut == nil)
        #expect(merged.rules.count == 2)
        #expect(merged.rules[0] == existingRule)
        #expect(merged.rules[1].id != existingRule.id)
        #expect(merged.rules[1].profileID == merged.profiles[1].id)
        // Same displays and port as the existing rule: imported disabled to avoid two rules fighting.
        #expect(!merged.rules[1].isEnabled)
        #expect(merged.knownPorts.map(\.name) == ["Mine", "Side"])

        #expect(summary.addedProfiles == 2)
        #expect(summary.renamedProfiles == 1)
        #expect(summary.removedShortcuts == 1)
        #expect(summary.addedRules == 1)
        #expect(summary.disabledRules == 1)
        #expect(summary.addedPorts == 1)
    }

    @Test func replaceAllUsesTheImportedDocument() {
        let existing = LayoutDocument(profiles: [deskProfile()])
        let imported = LayoutDocument(profiles: [macBookOnlyProfile()], knownPorts: [KnownPort(connection: usbC(1), name: "")])
        let (merged, summary) = ImportValidator.merge(imported, into: existing, mode: .replaceAll)
        #expect(merged.profiles == imported.profiles)
        #expect(merged.knownPorts == imported.knownPorts)
        #expect(summary.addedProfiles == 1)
        #expect(summary.addedPorts == 1)
    }

    @Test func uniqueNames() {
        #expect(ImportValidator.uniqueName(for: "Desk", used: []) == "Desk")
        #expect(ImportValidator.uniqueName(for: "Desk", used: ["desk"]) == "Desk 2")
        #expect(ImportValidator.uniqueName(for: "Desk", used: ["desk", "desk 2", "desk 3"]) == "Desk 4")
    }
}

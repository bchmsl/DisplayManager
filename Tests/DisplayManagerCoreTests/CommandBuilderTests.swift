import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct CommandBuilderTests {
    @Test func buildsArgumentsWithIDMapping() throws {
        let arguments = try CommandBuilder.arguments(
            for: deskProfile().screens,
            idMap: [TestIDs.external: "DDDDDDDD-0000-0000-0000-000000000000"])
        #expect(arguments == [
            "id:DDDDDDDD-0000-0000-0000-000000000000 res:3008x1692 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0",
            "id:\(TestIDs.builtIn) res:1512x982 hz:120 color_depth:8 enabled:true scaling:on origin:(3008,608) degree:0",
        ])
    }

    @Test func applyArgumentsUseLiveIDs() throws {
        let resolution = DisplayResolution(
            savedToLive: [TestIDs.external: "EEEEEEEE-0000-0000-0000-000000000000", TestIDs.builtIn: TestIDs.builtIn],
            unresolvedSavedIDs: [])
        let arguments = try CommandBuilder.applyArguments(for: deskProfile(), resolution: resolution)
        #expect(arguments.count == 2)
        #expect(arguments[0].hasPrefix("id:EEEEEEEE-0000-0000-0000-000000000000 "))
        #expect(arguments[1].hasPrefix("id:\(TestIDs.builtIn) "))
    }

    @Test func applyArgumentsDropDisabledDisplaysThatAreNotConnected() throws {
        var profile = deskProfile()
        profile.screens[1] = disabledScreen(TestIDs.builtIn)
        let resolution = DisplayResolution(savedToLive: [TestIDs.external: TestIDs.external], unresolvedSavedIDs: [TestIDs.builtIn])
        let arguments = try CommandBuilder.applyArguments(for: profile, resolution: resolution)
        #expect(arguments.count == 1)
        #expect(arguments[0].hasPrefix("id:\(TestIDs.external) "))
    }

    @Test func applyArgumentsKeepDisabledDisplaysThatAreConnected() throws {
        var profile = deskProfile()
        profile.screens[1] = disabledScreen(TestIDs.builtIn)
        let resolution = DisplayResolution(
            savedToLive: [TestIDs.external: TestIDs.external, TestIDs.builtIn: TestIDs.builtIn], unresolvedSavedIDs: [])
        let arguments = try CommandBuilder.applyArguments(for: profile, resolution: resolution)
        #expect(arguments == [
            "id:\(TestIDs.external) res:3008x1692 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0",
            "id:\(TestIDs.builtIn) enabled:false",
        ])
    }

    @Test func applyArgumentsRejectUnresolvedEnabledDisplay() {
        let resolution = DisplayResolution(savedToLive: [TestIDs.builtIn: TestIDs.builtIn], unresolvedSavedIDs: [TestIDs.external])
        #expect(throws: DisplayManagerError.self) {
            try CommandBuilder.applyArguments(for: deskProfile(), resolution: resolution)
        }
    }

    @Test func applyArgumentsMapEveryMirrorMember() throws {
        let profile = LayoutProfile(
            name: "Mirror", createdAt: .distantPast, updatedAt: .distantPast,
            screens: [ScreenSetting(displayIDs: [TestIDs.external, TestIDs.builtIn], resolution: DisplaySize(width: 1920, height: 1080), origin: .zero)],
            displays: [])
        let resolution = DisplayResolution(savedToLive: [TestIDs.external: "E1", TestIDs.builtIn: "B1"], unresolvedSavedIDs: [])
        #expect(try CommandBuilder.applyArguments(for: profile, resolution: resolution) == ["id:E1+B1 res:1920x1080 enabled:true origin:(0,0)"])
    }

    @Test func displayCommandPrefersConnectedIDs() throws {
        let profile = deskProfile()
        let full = DisplayResolution(savedToLive: [TestIDs.external: "E1", TestIDs.builtIn: "B1"], unresolvedSavedIDs: [])
        let connected = try CommandBuilder.displayCommand(for: profile, resolution: full)
        #expect(connected.usesConnectedDisplays)
        #expect(connected.arguments[0].hasPrefix("id:E1 "))

        let partial = DisplayResolution(savedToLive: [TestIDs.builtIn: "B1"], unresolvedSavedIDs: [TestIDs.external])
        let saved = try CommandBuilder.displayCommand(for: profile, resolution: partial)
        #expect(!saved.usesConnectedDisplays)
        #expect(saved.arguments[0].hasPrefix("id:\(TestIDs.external) "))

        #expect(try !CommandBuilder.displayCommand(for: profile, resolution: nil).usesConnectedDisplays)
    }

    @Test func rawCommandQuotesPathAndSpecs() {
        #expect(CommandBuilder.rawCommand(executablePath: "/opt/homebrew/bin/displayplacer", arguments: ["id:1 res:1x1", "id:2 enabled:false"])
            == #"/opt/homebrew/bin/displayplacer "id:1 res:1x1" "id:2 enabled:false""#)
        #expect(CommandBuilder.rawCommand(executablePath: nil, arguments: ["id:1"]) == #"displayplacer "id:1""#)
        #expect(CommandBuilder.rawCommand(executablePath: "/Users/me/My Tools/displayplacer", arguments: [])
            == "'/Users/me/My Tools/displayplacer'")
    }

    @Test func shellQuotingEscapesSingleQuotes() {
        #expect(CommandBuilder.shellQuoted("/tmp/it's/dp") == #"'/tmp/it'\''s/dp'"#)
        #expect(CommandBuilder.shellQuoted("") == "''")
        #expect(CommandBuilder.shellQuoted("/usr/local/bin/displayplacer") == "/usr/local/bin/displayplacer")
    }
}

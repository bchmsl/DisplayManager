import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct ListOutputParserTests {
    @Test func parsesRealTwoDisplayOutput() throws {
        let list = try ListOutputParser.parse(fixture("list-builtin-and-external.txt"))

        #expect(list.configuration == fixtureConfiguration)
        #expect(list.commandLine.hasPrefix("displayplacer \"id:\(TestIDs.builtIn) "))
        #expect(list.screens.count == 2)

        let builtIn = try #require(list.screen(persistentID: TestIDs.builtIn))
        #expect(builtIn.contextualID == 1)
        #expect(builtIn.serialID == "s1000000001")
        #expect(builtIn.typeDescription == "MacBook built in screen")
        #expect(builtIn.looksBuiltIn)
        #expect(builtIn.isMain)
        #expect(builtIn.origin == .zero)
        #expect(builtIn.rotation == 0)
        #expect(builtIn.enabled == true)
        #expect(builtIn.modesRotation == 0)
        #expect(builtIn.modes.count == 132)
        let current = try #require(builtIn.modes.first { $0.isCurrent })
        #expect(current.number == 66)
        #expect(current.resolution == DisplaySize(width: 1800, height: 1169))
        #expect(current.refreshRate == 120)
        #expect(current.scaling)

        let external = try #require(list.screen(persistentID: TestIDs.external))
        #expect(external.contextualID == 3)
        #expect(!external.isMain)
        #expect(!external.looksBuiltIn)
        #expect(external.origin == DisplayPoint(x: -592, y: -1692))
        #expect(external.modes.count == 156)
        #expect(external.modes.contains { $0.resolution == DisplaySize(width: 3008, height: 1692) && !$0.scaling })
    }

    @Test func rotationHintTextIsIgnored() throws {
        let list = try ListOutputParser.parse(fixture("list-builtin-and-external.txt"))
        let builtIn = try #require(list.screen(persistentID: TestIDs.builtIn))
        #expect(builtIn.rotation == 0)
        #expect(builtIn.extraFields.isEmpty)
    }

    @Test func parsesSyntheticMirroredOutput() throws {
        let list = try ListOutputParser.parse(fixture("list-synthetic-mirrored.txt"))
        #expect(list.configuration.count == 1)
        #expect(list.configuration[0].displayIDs == [TestIDs.external, TestIDs.builtIn])
        #expect(list.screens.count == 2)
    }

    @Test func parsesSyntheticDisabledOutput() throws {
        let list = try ListOutputParser.parse(fixture("list-synthetic-disabled.txt"))
        #expect(list.configuration.map(\.enabled) == [true, false])
        let builtIn = try #require(list.screen(persistentID: TestIDs.builtIn))
        #expect(builtIn.enabled == false)
        #expect(builtIn.resolution == nil)
        #expect(builtIn.modes.isEmpty)
    }

    @Test func parsesSyntheticClamshellOutput() throws {
        let list = try ListOutputParser.parse(fixture("list-synthetic-clamshell.txt"))
        #expect(list.screens.count == 1)
        #expect(list.configuration == [screen(TestIDs.external, res: (3008, 1692), origin: (0, 0))])
    }

    @Test func parsesSyntheticThreeDisplayOutput() throws {
        let list = try ListOutputParser.parse(fixture("list-synthetic-three-displays.txt"))
        #expect(list.screens.count == 3)
        #expect(list.configuration.count == 3)
        let rotated = try #require(list.screen(persistentID: TestIDs.third))
        #expect(rotated.rotation == 90)
        #expect(rotated.modesRotation == 90)
        #expect(list.configuration[2].rotation == 90)
        #expect(list.configuration[1].scaling == false)
    }

    @Test func missingCommandLineIsMalformed() throws {
        var text = try fixture("list-builtin-and-external.txt")
        text = text.components(separatedBy: "\n").filter { !$0.hasPrefix("displayplacer \"") }.joined(separator: "\n")
        #expect(throws: DisplayManagerError.self) { try ListOutputParser.parse(text) }
    }

    @Test(arguments: ["", "garbage\nmore garbage", "displayplacer \"unterminated", "displayplacer \"res:1x1\""])
    func garbageIsMalformed(_ text: String) {
        #expect(throws: DisplayManagerError.self) { try ListOutputParser.parse(text) }
    }

    @Test func tokenizerHandlesQuotes() throws {
        #expect(try ListOutputParser.tokenize(#"displayplacer "id:1 res:1x1" 'id:2 enabled:false'"#)
            == ["displayplacer", "id:1 res:1x1", "id:2 enabled:false"])
    }

    @Test func parsesModeLineVariants() throws {
        let scaled = try #require(ListOutputParser.parseMode("mode 66: res:1800x1169 hz:120 color_depth:8 scaling:on <-- current mode"))
        #expect(scaled.isCurrent && scaled.scaling && scaled.number == 66)
        let plain = try #require(ListOutputParser.parseMode("mode 0: res:800x600 hz:60 color_depth:8"))
        #expect(!plain.isCurrent && !plain.scaling && plain.colorDepth == 8)
        #expect(ListOutputParser.parseMode("mode x: res:800x600") == nil)
    }
}

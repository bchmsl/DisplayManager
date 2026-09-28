import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct ScreenSpecCodecTests {
    @Test func decodesFullSpec() throws {
        let setting = try ScreenSpecCodec.decode(
            "id:BBBBBBBB-5555-6666-7777-888888888888 res:3008x1692 hz:60 color_depth:8 enabled:true scaling:on origin:(-592,-1692) degree:0")
        #expect(setting.displayIDs == [TestIDs.external])
        #expect(setting.enabled)
        #expect(setting.resolution == DisplaySize(width: 3008, height: 1692))
        #expect(setting.refreshRate == 60)
        #expect(setting.colorDepth == 8)
        #expect(setting.scaling == true)
        #expect(setting.origin == DisplayPoint(x: -592, y: -1692))
        #expect(setting.rotation == 0)
        #expect(setting.extraArguments.isEmpty)
    }

    @Test func decodesMirrorSet() throws {
        let setting = try ScreenSpecCodec.decode("id:\(TestIDs.external)+\(TestIDs.builtIn) res:1920x1080 enabled:true origin:(0,0)")
        #expect(setting.displayIDs == [TestIDs.external, TestIDs.builtIn])
        #expect(setting.isMirrorSet)
        #expect(setting.primaryID == TestIDs.external)
    }

    @Test func decodesDisabledOnlySpec() throws {
        let setting = try ScreenSpecCodec.decode("id:\(TestIDs.builtIn) enabled:false")
        #expect(!setting.enabled)
        #expect(setting.resolution == nil)
        #expect(setting.origin == nil)
    }

    @Test func keepsUnknownTokensAndReemitsThem() throws {
        let setting = try ScreenSpecCodec.decode("id:1 mode:12 quiet:true enabled:true origin:(0,0)")
        #expect(setting.extraArguments == ["mode": "12", "quiet": "true"])
        let encoded = try ScreenSpecCodec.encode(setting)
        #expect(encoded == "id:1 enabled:true origin:(0,0) mode:12 quiet:true")
    }

    @Test func toleratesExtraWhitespace() throws {
        let setting = try ScreenSpecCodec.decode("  id:1   res:800x600\thz:60  enabled:true ")
        #expect(setting.displayIDs == ["1"])
        #expect(setting.resolution == DisplaySize(width: 800, height: 600))
    }

    @Test func encodesInDisplayplacerTokenOrder() throws {
        let setting = screen(TestIDs.external, res: (3008, 1692), hz: 60, origin: (0, 0))
        #expect(try ScreenSpecCodec.encode(setting)
            == "id:\(TestIDs.external) res:3008x1692 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0")
    }

    @Test func encodesDisabledScreenAsIdAndEnabledFalse() throws {
        var setting = screen(TestIDs.builtIn, res: (1512, 982), origin: (0, 0))
        setting.enabled = false
        #expect(try ScreenSpecCodec.encode(setting) == "id:\(TestIDs.builtIn) enabled:false")
    }

    @Test func roundTripsRealCommandSpecs() throws {
        let specs = [
            "id:AAAAAAAA-1111-2222-3333-444444444444 res:1800x1169 hz:120 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0",
            "id:BBBBBBBB-5555-6666-7777-888888888888 res:3008x1692 hz:60 color_depth:8 enabled:true scaling:off origin:(-592,-1692) degree:90",
        ]
        for spec in specs {
            #expect(try ScreenSpecCodec.encode(ScreenSpecCodec.decode(spec)) == spec)
        }
    }

    @Test(arguments: [
        "res:800x600 enabled:true",
        "id: res:800x600",
        "id:1 res:800by600",
        "id:1 origin:(1;2)",
        "id:1 enabled:maybe",
        "id:1 hz:sixty",
        "id:1 justaword",
        "id:1 res:800x600\"",
        "id:1 origin:(0,0)$(reboot)",
        "id:ab`cd",
        "",
    ])
    func rejectsInvalidSpecs(_ spec: String) {
        #expect(throws: DisplayManagerError.self) { try ScreenSpecCodec.decode(spec) }
    }

    @Test func rejectsUnsafeIDsOnEncode() {
        let setting = ScreenSetting(displayIDs: ["abc\"; rm -rf ~"], enabled: true, origin: .zero)
        #expect(throws: DisplayManagerError.self) { try ScreenSpecCodec.encode(setting) }
    }

    @Test func rejectsUnsafeExtraArgumentsOnEncode() {
        let setting = ScreenSetting(displayIDs: ["1"], enabled: true, origin: .zero, extraArguments: ["quiet": "$(id)"])
        #expect(throws: DisplayManagerError.self) { try ScreenSpecCodec.encode(setting) }
    }
}

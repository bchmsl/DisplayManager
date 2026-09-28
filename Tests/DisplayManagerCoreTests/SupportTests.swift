import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct KeyShortcutTests {
    @Test func sortsModifiersAndBuildsLabel() {
        let shortcut = KeyShortcut(keyCode: 18, modifiers: [.command, .option, .command], keyLabel: "1")
        #expect(shortcut.modifiers == [.option, .command])
        #expect(shortcut.displayString == "⌥⌘1")
        #expect(KeyShortcut(keyCode: 0, modifiers: KeyModifier.allCases.reversed(), keyLabel: "A").displayString == "⌃⌥⇧⌘A")
    }

    @Test func sameCombinationIgnoresLabel() {
        let a = KeyShortcut(keyCode: 18, modifiers: [.option, .command], displayString: "⌥⌘1")
        let b = KeyShortcut(keyCode: 18, modifiers: [.command, .option], displayString: "something else")
        #expect(a.sameCombination(as: b))
        #expect(!a.sameCombination(as: KeyShortcut(keyCode: 19, modifiers: [.option, .command], keyLabel: "2")))
        #expect(!a.sameCombination(as: KeyShortcut(keyCode: 18, modifiers: [.command], keyLabel: "1")))
    }
}

@Suite struct ShortcutValidatorTests {
    @Test func requiresAStrongModifier() {
        let shiftOnly = KeyShortcut(keyCode: 18, modifiers: [.shift], keyLabel: "1")
        #expect(ShortcutValidator.validate(shiftOnly, for: UUID(), profiles: []) == .missingModifier)
        let none = KeyShortcut(keyCode: 18, modifiers: [], keyLabel: "1")
        #expect(ShortcutValidator.validate(none, for: UUID(), profiles: []) == .missingModifier)
        let control = KeyShortcut(keyCode: 18, modifiers: [.control, .shift], keyLabel: "1")
        #expect(ShortcutValidator.validate(control, for: UUID(), profiles: []) == nil)
    }

    @Test func rejectsDuplicatesOnOtherProfilesOnly() {
        var desk = deskProfile()
        desk.shortcut = KeyShortcut(keyCode: 18, modifiers: [.option, .command], keyLabel: "1")
        let same = KeyShortcut(keyCode: 18, modifiers: [.command, .option], keyLabel: "1")
        #expect(ShortcutValidator.validate(same, for: UUID(), profiles: [desk]) == .duplicate(profileName: "Desk"))
        #expect(ShortcutValidator.validate(same, for: desk.id, profiles: [desk]) == nil)
    }
}

@Suite struct PreviewGeometryTests {
    @Test func profilePreviewUsesSavedGeometry() {
        let model = PreviewGeometry.model(for: deskProfile(), connectedIDs: [TestIDs.builtIn.lowercased()])
        #expect(model.items.count == 2)
        #expect(model.disabledNames.isEmpty)
        let external = model.items[0]
        #expect(external.rect == DisplayRect(x: 0, y: 0, width: 3008, height: 1692))
        #expect(external.isMain)
        #expect(!external.isConnected)
        #expect(external.names == ["Mi Monitor"])
        let builtIn = model.items[1]
        #expect(builtIn.rect == DisplayRect(x: 3008, y: 608, width: 1512, height: 982))
        #expect(!builtIn.isMain)
        #expect(builtIn.isConnected)
    }

    @Test func rotationAndBoundsDecideTheSize() {
        #expect(PreviewGeometry.displaySize(bounds: nil, resolution: DisplaySize(width: 1920, height: 1080), rotation: 90) == DisplaySize(width: 1080, height: 1920))
        #expect(PreviewGeometry.displaySize(bounds: nil, resolution: DisplaySize(width: 1920, height: 1080), rotation: 180) == DisplaySize(width: 1920, height: 1080))
        #expect(PreviewGeometry.displaySize(bounds: DisplayRect(x: 0, y: 0, width: 1080, height: 1920), resolution: DisplaySize(width: 1080, height: 1920), rotation: 90)
            == DisplaySize(width: 1080, height: 1920))
        #expect(PreviewGeometry.displaySize(bounds: nil, resolution: nil, rotation: 0) == DisplaySize(width: 1920, height: 1080))
    }

    @Test func disabledAndMirroredScreens() {
        var profile = deskProfile()
        profile.screens = [
            ScreenSetting(displayIDs: [TestIDs.external, TestIDs.builtIn], resolution: DisplaySize(width: 1920, height: 1080), origin: .zero),
        ]
        let mirrored = PreviewGeometry.model(for: profile, connectedIDs: [TestIDs.external, TestIDs.builtIn])
        #expect(mirrored.items.count == 1)
        #expect(mirrored.items[0].isMirrored)
        #expect(mirrored.items[0].isConnected)
        #expect(mirrored.items[0].rect.size == DisplaySize(width: 1920, height: 1080)) // no saved bounds: the mirror resolution

        profile.displays[0].bounds = DisplayRect(x: 0, y: 0, width: 1920, height: 1200)
        let withBounds = PreviewGeometry.model(for: profile, connectedIDs: [])
        #expect(withBounds.items[0].rect.size == DisplaySize(width: 1920, height: 1200)) // saved bounds of the first display win

        profile.screens = [deskProfile().screens[0], disabledScreen(TestIDs.builtIn)]
        let disabled = PreviewGeometry.model(for: profile, connectedIDs: [])
        #expect(disabled.items.count == 1)
        #expect(disabled.disabledNames == ["Built-in Retina Display"])
    }

    @Test func livePreviewUsesConfigurationOrBounds() {
        let snapshot = makeSnapshot(displays: [.external(), .builtIn()], configuration: fixtureConfiguration)
        let model = PreviewGeometry.model(for: snapshot)
        #expect(model.items.map(\.names) == [["Built-in Retina Display"], ["Mi Monitor"]])
        #expect(model.items[1].rect == DisplayRect(x: -592, y: -1692, width: 3008, height: 1692))

        var noConfig = makeSnapshot(displays: [.builtIn()], configuration: nil)
        noConfig.displays[0].bounds = DisplayRect(x: 0, y: 0, width: 1512, height: 982)
        noConfig.displays[0].isMain = true
        let fallback = PreviewGeometry.model(for: noConfig)
        #expect(fallback.items.count == 1)
        #expect(fallback.items[0].rect.size == DisplaySize(width: 1512, height: 982))
        #expect(fallback.items[0].isMain)
    }

    @Test func framesKeepProportionsAndCenter() throws {
        let model = PreviewGeometry.model(for: deskProfile(), connectedIDs: [])
        let frames = PreviewGeometry.frames(for: model.items, canvasWidth: 460, canvasHeight: 200, padding: 4)
        let external = try #require(frames[TestIDs.external])
        let builtIn = try #require(frames[TestIDs.builtIn])
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        #expect(close(external.x, 4) && close(external.y, 15.4) && close(external.width, 300.8) && close(external.height, 169.2))
        #expect(close(builtIn.x, 304.8) && close(builtIn.y, 76.2) && close(builtIn.width, 151.2) && close(builtIn.height, 98.2))
        #expect(close(external.width / external.height, 3008.0 / 1692.0))
        #expect(PreviewGeometry.frames(for: [], canvasWidth: 100, canvasHeight: 100, padding: 0).isEmpty)
        #expect(PreviewGeometry.frames(for: model.items, canvasWidth: 0, canvasHeight: 100, padding: 0).isEmpty)
    }
}

@Suite struct PluralTests {
    @Test func countsWithTheRightForm() {
        #expect(counted(0, "layout") == "0 layouts")
        #expect(counted(1, "layout") == "1 layout")
        #expect(counted(2, "rule") == "2 rules")
    }
}

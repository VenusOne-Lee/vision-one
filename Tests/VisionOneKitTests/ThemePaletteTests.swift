import XCTest
@testable import VisionOneKit

final class ThemePaletteTests: XCTestCase {
    private let rings: [UInt32] = [DesignTokens.ringBlue, DesignTokens.ringRed, DesignTokens.ringGold,
                                   DesignTokens.accentPurple, DesignTokens.accentPink, DesignTokens.ringBlack]

    func testEveryPresetWithEveryRingPassesContrast() {
        for preset in ThemePreset.allCases {
            for ring in rings {
                for increase in [false, true] {
                    var a = Appearance.standard.applying(preset)
                    a.accent = ring
                    let p = ThemePalette.resolve(a, increaseContrast: increase)
                    XCTAssertEqual(p.failures, [], "\(preset.title), ring \(Appearance.hexString(ring)), increase \(increase)")
                }
            }
        }
    }

    func testPaperIsDesignMdAsWritten() {
        let p = ThemePalette.resolve(.standard)
        XCTAssertEqual(p.paper, DesignTokens.paper)
        XCTAssertEqual(p.canvas, DesignTokens.canvas)
        XCTAssertEqual(p.text, DesignTokens.text)
        XCTAssertEqual(p.button, DesignTokens.text)
        XCTAssertEqual(p.onButton, 0xFFFFFF)
        XCTAssertFalse(p.isDark)
        XCTAssertEqual(Appearance.standard.preset, .paper)
    }

    func testTallyNeverChanges() {
        for preset in ThemePreset.allCases {
            let p = ThemePalette.resolve(Appearance.standard.applying(preset))
            XCTAssertNotEqual(p.button, ThemePalette.tally, preset.title)
        }
        var a = Appearance.standard.applying(.bold)
        a.accent = DesignTokens.tally
        XCTAssertEqual(ThemePalette.resolve(a).button, DesignTokens.text)
        XCTAssertEqual(ThemePalette.tally, 0xFF5A1F)
    }

    func testOrangeRedGreenAndGreyRingsKeepInkButtons() {
        XCTAssertNotNil(ThemePalette.buttonRefusal(for: DesignTokens.tally))
        XCTAssertNotNil(ThemePalette.buttonRefusal(for: DesignTokens.ringRed))
        XCTAssertNotNil(ThemePalette.buttonRefusal(for: DesignTokens.ringGold))
        XCTAssertNotNil(ThemePalette.buttonRefusal(for: 0x1E8E3E))
        XCTAssertNotNil(ThemePalette.buttonRefusal(for: DesignTokens.ringBlack))
        XCTAssertNil(ThemePalette.buttonRefusal(for: DesignTokens.ringBlue))
        XCTAssertNil(ThemePalette.buttonRefusal(for: DesignTokens.accentPurple))
        XCTAssertNil(ThemePalette.buttonRefusal(for: DesignTokens.accentPink))

        var a = Appearance.standard.applying(.bold)
        a.accent = DesignTokens.ringRed
        XCTAssertEqual(ThemePalette.resolve(a).button, DesignTokens.text)
        a.accent = DesignTokens.ringBlue
        XCTAssertEqual(ThemePalette.resolve(a).button, DesignTokens.ringBlue)
    }

    func testBoldButtonsLightenInStudio() {
        var a = Appearance.standard.applying(.studio)
        a.buttons = .accent
        a.accent = DesignTokens.ringBlue
        let p = ThemePalette.resolve(a)
        XCTAssertTrue(p.isDark)
        XCTAssertNotEqual(p.button, DesignTokens.ringBlue)
        XCTAssertGreaterThanOrEqual(DesignTokens.contrast(p.button, p.paper), 3)
    }

    func testPresetsMatchThemselvesAndKeepPersonalChoices() {
        var a = Appearance.standard
        a.corners = .round
        a.density = .roomy
        a.accent = DesignTokens.accentPink
        for preset in ThemePreset.allCases {
            let b = a.applying(preset)
            XCTAssertEqual(b.preset, preset)
            XCTAssertEqual(b.corners, .round)
            XCTAssertEqual(b.density, .roomy)
            XCTAssertEqual(b.accent, DesignTokens.accentPink)
        }
        var custom = Appearance.standard.applying(.warm)
        custom.buttons = .accent
        XCTAssertNil(custom.preset)
    }

    func testThemeFileRoundTripsAndToleratesMissingKeys() throws {
        var a = Appearance.standard.applying(.cool)
        a.accent = DesignTokens.accentPurple
        a.transcriptFont = .easyRead
        a.panelSide = .left
        let data = try AppearanceFile.encode(a)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"#7A3FBF\""))
        XCTAssertEqual(try AppearanceFile.decode(data), a)

        let partial = Data(#"{"tone":"warm","accent":"c2306e","density":"sideways"}"#.utf8)
        let b = try AppearanceFile.decode(partial)
        XCTAssertEqual(b.tone, .warm)
        XCTAssertEqual(b.accent, DesignTokens.accentPink)
        XCTAssertEqual(b.density, Appearance.standard.density)
        XCTAssertEqual(b.mode, .light)
    }

    func testSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("theme.json")
        XCTAssertEqual(AppearanceFile.load(from: url), .standard)
        let a = Appearance.standard.applying(.highContrast)
        try AppearanceFile.save(a, to: url)
        XCTAssertEqual(AppearanceFile.load(from: url), a)
    }

    func testHexParsing() {
        XCTAssertEqual(Appearance.parseHex("#1F3FBF"), 0x1F3FBF)
        XCTAssertEqual(Appearance.parseHex(" 1f3fbf "), 0x1F3FBF)
        XCTAssertNil(Appearance.parseHex("#FFF"))
        XCTAssertNil(Appearance.parseHex("zzzzzz"))
        XCTAssertEqual(Appearance.hexString(0x0000FF), "#0000FF")
    }
}

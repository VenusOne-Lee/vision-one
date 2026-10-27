import XCTest
@testable import VisionOneKit

final class DesignTokensTests: XCTestCase {
    func testContrastMatchesKnownValues() {
        XCTAssertEqual(DesignTokens.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(DesignTokens.contrast(0xFFFFFF, 0xFFFFFF), 1, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.contrast(DesignTokens.text, DesignTokens.paper), 18.7, accuracy: 0.1)
    }

    func testTextPairsMeetAA() {
        for pair in DesignTokens.textPairs {
            let ratio = DesignTokens.contrast(pair.foreground, pair.background)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(pair.name) is \(ratio):1")
        }
    }

    func testControlEdgesAndFocusMeetThreeToOne() {
        for pair in DesignTokens.markPairs {
            let ratio = DesignTokens.contrast(pair.foreground, pair.background)
            XCTAssertGreaterThanOrEqual(ratio, 3, "\(pair.name) is \(ratio):1")
        }
    }

    func testDecorativeLineIsTooFaintForControls() {
        // Why controls use lineStrong: the panel line can't mark a control.
        XCTAssertLessThan(DesignTokens.contrast(DesignTokens.line, DesignTokens.paper), 3)
    }

    func testErrorAndTallyStayApart() {
        // Error red is darker than tally so they never read as one signal.
        XCTAssertLessThan(DesignTokens.luminance(DesignTokens.error), DesignTokens.luminance(DesignTokens.tally))
    }
}

final class ShortcutMapTests: XCTestCase {
    func testNoTwoShortcutsShareKeys() {
        XCTAssertEqual(ShortcutMap.clashes(), [])
    }

    func testNoShortcutTakesAStandardMacShortcut() {
        XCTAssertEqual(ShortcutMap.reservedClashes(), [])
    }

    func testClashesAreFound() {
        let a = ShortcutSpec("a", "A", menu: "File", key: .character("e"), modifiers: [.command])
        let b = ShortcutSpec("b", "B", menu: "Edit", key: .character("e"), modifiers: [.command])
        XCTAssertEqual(ShortcutMap.clashes(in: [a, b]), [["a", "b"]])
        let quit = ShortcutSpec("q", "Quit-ish", menu: "File", key: .character("q"), modifiers: [.command])
        XCTAssertEqual(ShortcutMap.reservedClashes(in: [quit]), ["q"])
    }

    func testDisplayUsesMacOrder() {
        XCTAssertEqual(ShortcutMap.record.display, "⇧⌘R")
        XCTAssertEqual(ShortcutMap.acceptAll.display, "⌘⏎")
        XCTAssertEqual(ShortcutMap.playPause.display, "Space")
    }

    func testEveryEntryHasAKnownMenuAndUniqueID() {
        XCTAssertEqual(Set(ShortcutMap.all.map(\.id)).count, ShortcutMap.all.count)
        for spec in ShortcutMap.all {
            XCTAssertTrue(ShortcutMap.menus.contains(spec.menu), spec.id)
        }
        XCTAssertEqual(ShortcutMap.spec("export"), ShortcutMap.export)
    }
}

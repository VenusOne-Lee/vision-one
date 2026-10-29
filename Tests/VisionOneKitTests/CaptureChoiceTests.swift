import XCTest
@testable import VisionOneKit

final class CaptureRectTests: XCTestCase {
    func testBetweenWorksInAnyDirection() {
        let rect = CaptureRect.between(300, 200, 100, 50)
        XCTAssertEqual(rect, CaptureRect(x: 100, y: 50, width: 200, height: 150))
    }

    func testClampsToDisplay() {
        let display = CaptureRect(x: 0, y: 0, width: 1512, height: 982)
        let rect = CaptureRect(x: 1400, y: -20, width: 300, height: 200)
        XCTAssertEqual(rect.clamped(to: display), CaptureRect(x: 1400, y: 0, width: 112, height: 180))
        XCTAssertNil(CaptureRect(x: 2000, y: 0, width: 100, height: 100).clamped(to: display))
    }

    func testTooSmallAreaIsRejected() {
        XCTAssertFalse(CaptureRect(x: 0, y: 0, width: 63, height: 400).isBigEnough)
        XCTAssertTrue(CaptureRect(x: 0, y: 0, width: 64, height: 64).isBigEnough)
    }

    func testMoveStaysOnScreen() {
        let display = CaptureRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CaptureRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(rect.moved(dx: 50, dy: -20, within: display), CaptureRect(x: 150, y: 80, width: 400, height: 300))
        XCTAssertEqual(rect.moved(dx: 900, dy: -500, within: display), CaptureRect(x: 600, y: 0, width: 400, height: 300))
    }

    func testResizeFromACorner() {
        let display = CaptureRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CaptureRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(rect.resized([.right, .bottom], dx: 100, dy: 50, within: display),
                       CaptureRect(x: 100, y: 100, width: 500, height: 350))
        XCTAssertEqual(rect.resized([.left, .top], dx: -200, dy: -200, within: display),
                       CaptureRect(x: 0, y: 0, width: 500, height: 400))
    }

    func testResizeNeverFlipsOrShrinksBelowMinimum() {
        let display = CaptureRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CaptureRect(x: 100, y: 100, width: 400, height: 300)
        let squashed = rect.resized(.left, dx: 1000, dy: 0, within: display)
        XCTAssertEqual(squashed, CaptureRect(x: 436, y: 100, width: 64, height: 300))
        XCTAssertEqual(rect.resized(.bottom, dx: 0, dy: 900, within: display).height, 700)
    }

    func testPixelSizeIsEven() {
        let size = CaptureRect(x: 0, y: 0, width: 640.75, height: 360.5).pixelSize(scale: 2)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
        let odd = CaptureRect(x: 0, y: 0, width: 101, height: 75).pixelSize(scale: 1)
        XCTAssertEqual(odd.width, 100)
        XCTAssertEqual(odd.height, 74)
    }
}

final class CaptureChoiceTests: XCTestCase {
    func testDefaultRecordsWholeScreenWithSound() {
        let choice = CaptureChoice()
        XCTAssertEqual(choice.mode, .screen)
        XCTAssertTrue(choice.includeMicrophone)
        XCTAssertTrue(choice.includeSystemSound)
        XCTAssertNil(choice.missingStep)
    }

    func testWindowAndAreaNeedAPick() {
        XCTAssertEqual(CaptureChoice(mode: .window).missingStep, .pickWindow)
        XCTAssertNil(CaptureChoice(mode: .window, windowID: 42).missingStep)
        XCTAssertEqual(CaptureChoice(mode: .area).missingStep, .dragArea)
        XCTAssertEqual(CaptureChoice(mode: .area, area: CaptureRect(x: 0, y: 0, width: 10, height: 10)).missingStep, .dragArea)
        XCTAssertNil(CaptureChoice(mode: .area, area: CaptureRect(x: 0, y: 0, width: 640, height: 360)).missingStep)
    }

    func testCameraOnlyNeedsNothingPicked() throws {
        let choice = CaptureChoice(mode: .camera)
        XCTAssertNil(choice.missingStep)
        XCTAssertFalse(CaptureMode.camera.recordsScreen)
        XCTAssertTrue(CaptureMode.area.recordsScreen)
        XCTAssertEqual(CaptureMode.camera.menuTitle, "Camera only")
        XCTAssertEqual(CaptureMode.window.menuTitle, "Window")
        XCTAssertEqual(CaptureChoice.decoded(from: try choice.encoded()).mode, .camera)
    }

    func testRoundTripsAndFallsBackToDefault() throws {
        let choice = CaptureChoice(mode: .area, displayID: 2, area: CaptureRect(x: 10, y: 20, width: 640, height: 360),
                                   includeMicrophone: false, includeSystemSound: true)
        XCTAssertEqual(CaptureChoice.decoded(from: try choice.encoded()), choice)
        XCTAssertEqual(CaptureChoice.decoded(from: Data("nonsense".utf8)), CaptureChoice())
        XCTAssertEqual(CaptureChoice.decoded(from: nil), CaptureChoice())
    }
}

final class WindowCandidateTests: XCTestCase {
    private func window(_ id: UInt32, _ app: String, _ title: String?, bundle: String? = nil,
                        size: Double = 800, layer: Int = 0, onScreen: Bool = true) -> WindowCandidate {
        WindowCandidate(id: id, appName: app, bundleID: bundle, title: title,
                        width: size, height: size, layer: layer, isOnScreen: onScreen)
    }

    func testLabel() {
        XCTAssertEqual(window(1, "Safari", "Version One").label, "Safari: Version One")
        XCTAssertEqual(window(2, "Finder", nil).label, "Finder")
        XCTAssertEqual(window(3, "Notes", "").label, "Notes")
        XCTAssertEqual(window(4, "Xcode", "Xcode").label, "Xcode")
    }

    func testKeepsOnlyNormalVisibleWindowsSorted() {
        let windows = [
            window(1, "Safari", "Version One"),
            window(2, "Dock", nil, layer: 20),
            window(3, "Vision One", "Get set up", bundle: "za.co.versionone.visionone"),
            window(4, "Notes", "Ideas", onScreen: false),
            window(5, "Tiny", "Tooltip", size: 20),
            window(6, "Arc", "Docs"),
            window(7, "Safari", "GitHub"),
        ]
        let picked = WindowCandidate.pickable(windows, excludingBundleID: "za.co.versionone.visionone")
        XCTAssertEqual(picked.map(\.id), [6, 7, 1])
    }
}

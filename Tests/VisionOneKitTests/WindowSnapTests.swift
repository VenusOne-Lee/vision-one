import XCTest
@testable import VisionOneKit

final class WindowSnapTests: XCTestCase {
    private let front = CaptureRect(x: 100, y: 100, width: 400, height: 300)
    private let back = CaptureRect(x: 50, y: 50, width: 800, height: 600)

    func testClickPicksTheFrontWindow() {
        XCTAssertEqual(WindowSnap.window(at: (200, 200), in: [front, back]), front)
        XCTAssertEqual(WindowSnap.window(at: (60, 60), in: [front, back]), back)
        XCTAssertNil(WindowSnap.window(at: (5, 5), in: [front, back]))
    }

    func testNearbyEdgesSnap() {
        let drawn = CaptureRect(x: 104, y: 95, width: 390, height: 310)
        let snapped = WindowSnap.snap(drawn, edges: [.left, .right, .top, .bottom], to: [front])
        XCTAssertEqual(snapped, front)
    }

    func testOnlyTheMovingEdgesSnap() {
        let drawn = CaptureRect(x: 104, y: 95, width: 390, height: 310)
        let snapped = WindowSnap.snap(drawn, edges: [.right], to: [front])
        XCTAssertEqual(snapped.x, 104)
        XCTAssertEqual(snapped.x + snapped.width, 500)
        XCTAssertEqual(snapped.y, 95)
    }

    func testFarEdgesStay() {
        let drawn = CaptureRect(x: 200, y: 200, width: 100, height: 100)
        XCTAssertEqual(WindowSnap.snap(drawn, edges: [.left, .right, .top, .bottom], to: [front]), drawn)
    }
}

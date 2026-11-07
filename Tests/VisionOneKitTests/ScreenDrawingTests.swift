import XCTest
@testable import VisionOneKit

final class ScreenDrawingTests: XCTestCase {
    private let stroke = ScreenDrawing.Stroke(points: [
        .init(t: 2.0, x: 0.1, y: 0.1),
        .init(t: 2.2, x: 0.2, y: 0.15),
        .init(t: 2.4, x: 0.3, y: 0.2),
    ])

    func testNothingShowsBeforeTheStroke() {
        XCTAssertTrue(ScreenDrawing(strokes: [stroke]).visible(atSource: 1.9).isEmpty)
    }

    func testStrokeDrawsOnAsItWasDrawn() {
        let shown = ScreenDrawing(strokes: [stroke]).visible(atSource: 2.25)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].points.count, 2)
        XCTAssertEqual(shown[0].opacity, 1)
    }

    func testStrokeHoldsThenFades() {
        let drawing = ScreenDrawing(strokes: [stroke])
        XCTAssertEqual(drawing.visible(atSource: 2.4 + 3.0)[0].opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(drawing.visible(atSource: 2.4 + 3.25)[0].opacity, 0.5, accuracy: 1e-9)
        XCTAssertTrue(drawing.visible(atSource: 2.4 + 3.5).isEmpty)
    }

    func testEmptyStrokesAreDroppedAndOrderIsByStart() {
        let late = ScreenDrawing.Stroke(points: [.init(t: 9, x: 0.5, y: 0.5)])
        let drawing = ScreenDrawing(strokes: [late, .init(points: []), stroke])
        XCTAssertEqual(drawing.strokes.map(\.start), [2.0, 9])
    }

    func testRoundTripsThroughTheTakeFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = Take(folder: folder).drawingsURL
        XCTAssertNil(ScreenDrawing.read(from: url))
        let drawing = ScreenDrawing(strokes: [stroke])
        try drawing.write(to: url)
        XCTAssertEqual(ScreenDrawing.read(from: url), drawing)
        XCTAssertEqual(url.lastPathComponent, "drawings.json")
    }
}

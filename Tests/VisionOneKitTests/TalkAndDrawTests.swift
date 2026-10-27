import XCTest
@testable import VisionOneKit

final class SpokenEditTests: XCTestCase {
    func testPointingCuts() {
        XCTAssertEqual(SpokenEdit.parse("Cut this bit."), .cutSentence)
        XCTAssertEqual(SpokenEdit.parse("lose that sentence"), .cutSentence)
        XCTAssertEqual(SpokenEdit.parse("cut this word"), .cutWord)
    }

    func testZooms() {
        XCTAssertEqual(SpokenEdit.parse("zoom in on the queue count here"), .zoomIn)
        XCTAssertEqual(SpokenEdit.parse("Zoom out"), .zoomOut)
        XCTAssertEqual(SpokenEdit.parse("don’t zoom here"), .zoomOut)
    }

    func testOthers() {
        XCTAssertEqual(SpokenEdit.parse("blur this"), .blur)
        XCTAssertEqual(SpokenEdit.parse("make the music quieter"), .music(louder: false))
        XCTAssertEqual(SpokenEdit.parse("music up a bit"), .music(louder: true))
        XCTAssertEqual(SpokenEdit.parse("undo that"), .undo)
    }

    func testLongerAsksGoToAsk() {
        XCTAssertEqual(SpokenEdit.parse("cut where nobody is talking"), .ask("cut where nobody is talking"))
        XCTAssertEqual(SpokenEdit.parse("make it under a minute"), .ask("make it under a minute"))
    }

    func testSentenceAtTime() {
        let sentences = [
            SpokenSentence(index: 0, wordIDs: [0], text: "One.", start: 1, end: 4),
            SpokenSentence(index: 1, wordIDs: [1], text: "Two.", start: 6, end: 9),
        ]
        XCTAssertEqual(SpokenEdit.sentence(at: 2, in: sentences)?.index, 0)
        XCTAssertEqual(SpokenEdit.sentence(at: 5, in: sentences)?.index, 0)
        XCTAssertEqual(SpokenEdit.sentence(at: 11, in: sentences)?.index, 1)
        XCTAssertNil(SpokenEdit.sentence(at: 20, in: sentences))
    }
}

final class StrokeShapeTests: XCTestCase {
    private func circle(cx: Double, cy: Double, r: Double, turns: Double = 1) -> [StrokePoint] {
        (0...60).map { i in
            let a = Double(i) / 60 * 2 * .pi * turns
            return StrokePoint(x: cx + r * cos(a), y: cy + r * sin(a))
        }
    }

    func testCircle() {
        guard case let .circle(minX, minY, maxX, maxY)? = StrokeShape.classify(circle(cx: 100, cy: 80, r: 40)) else {
            return XCTFail("expected a circle")
        }
        XCTAssertEqual(minX, 60, accuracy: 1)
        XCTAssertEqual(maxX, 140, accuracy: 1)
        XCTAssertEqual(minY, 40, accuracy: 1)
        XCTAssertEqual(maxY, 120, accuracy: 1)
    }

    func testMostlyClosedLoopIsACircle() {
        guard case .circle? = StrokeShape.classify(circle(cx: 0, cy: 0, r: 50, turns: 0.85)) else {
            return XCTFail("expected a circle")
        }
    }

    func testScribble() {
        var points: [StrokePoint] = []
        for i in 0..<8 {
            let y = Double(i) * 4
            points.append(StrokePoint(x: i.isMultiple(of: 2) ? 0 : 120, y: y))
        }
        guard case .scribble? = StrokeShape.classify(points) else { return XCTFail("expected a scribble") }
    }

    func testLine() {
        let points = (0...20).map { StrokePoint(x: Double($0) * 10, y: Double($0) * 5 + ($0 == 10 ? 3 : 0)) }
        XCTAssertEqual(StrokeShape.classify(points), .line(from: points[0], to: points[20]))
    }

    func testTapIsNothing() {
        XCTAssertNil(StrokeShape.classify([StrokePoint(x: 0, y: 0), StrokePoint(x: 2, y: 1), StrokePoint(x: 3, y: 3)]))
    }
}

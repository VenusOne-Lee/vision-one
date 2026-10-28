import XCTest
@testable import VisionOneKit

final class TakeTimelineTests: XCTestCase {
    func testNamesRowsInTimeOrderWithinEachKind() {
        var edits = EditList(sourceDuration: 60)
        let late = Cut(span: TimeSpan(start: 30, end: 31), reason: Cut.Reason.filler)
        let early = Cut(span: TimeSpan(start: 5, end: 6), reason: Cut.Reason.pause, state: .proposed)
        edits.cuts = [late, early]
        let zooms = ZoomList(zooms: [Zoom(span: TimeSpan(start: 10, end: 14), scale: 1.5, centerX: 0.2, centerY: 0.2)])
        let blurs = BlurList(blurs: [Blur(span: TimeSpan(start: 0, end: 60), rect: FrameRect(x: 0, y: 0, width: 0.2, height: 0.1),
                                          kind: "OpenAI key", reason: Blur.Reason.secret, state: .proposed)])
        let timeline = TakeTimeline(edits: edits, zooms: zooms, blurs: blurs)
        XCTAssertEqual(timeline.rows.map(\.ref), ["b1", "c1", "z1", "c2"])
        XCTAssertEqual(timeline.row("C2")?.id, late.id)
        XCTAssertEqual(timeline.row("z1")?.detail, "1.5× zoom")
        XCTAssertEqual(timeline.lines[1], "c1  0:05.0–0:06.0  cut  proposed  pause")
    }

    func testChangesMatchRowsByIDEvenWhenRenumbered() {
        var edits = EditList(sourceDuration: 60)
        let a = Cut(span: TimeSpan(start: 10, end: 11), state: .proposed)
        let b = Cut(span: TimeSpan(start: 20, end: 21), state: .proposed)
        edits.cuts = [a, b]
        let before = TakeTimeline(edits: edits)

        edits.remove(id: a.id)
        edits.setState(.rejected, for: b.id)
        edits.cuts.append(Cut(span: TimeSpan(start: 2, end: 3), reason: Cut.Reason.word))
        let lines = TakeTimeline(edits: edits).changes(since: before)

        XCTAssertEqual(lines, [
            "Added cut c1 (0:02.0–0:03.0, word)",
            "Turned down cut c2 (0:20.0–0:21.0, word)",
            "Removed cut 0:10.0–0:11.0, word",
        ])
    }

    func testMovedRowsSayWhereTheyWere() {
        var edits = EditList(sourceDuration: 60)
        let cut = Cut(span: TimeSpan(start: 10, end: 11))
        edits.cuts = [cut]
        let before = TakeTimeline(edits: edits)
        edits.cuts[0].end = 12.5
        XCTAssertEqual(TakeTimeline(edits: edits).changes(since: before),
                       ["Moved cut c1 (0:10.0–0:12.5, word), was 0:10.0–0:11.0"])
        XCTAssertTrue(TakeTimeline(edits: edits).changes(since: TakeTimeline(edits: edits)).isEmpty)
    }
}

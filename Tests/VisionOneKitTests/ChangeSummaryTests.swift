import XCTest
@testable import VisionOneKit

final class ChangeSummaryTests: XCTestCase {
    private func cut(_ start: Double, _ end: Double, _ reason: String?, _ state: Cut.State = .proposed) -> Cut {
        Cut(span: TimeSpan(start: start, end: end), reason: reason, state: state)
    }

    private let words: [TranscriptWord] = [
        TranscriptWord(id: 0, text: "Um,", start: 0.0, end: 0.4),
        TranscriptWord(id: 1, text: "so", start: 0.5, end: 0.7),
        TranscriptWord(id: 2, text: "this", start: 0.8, end: 1.0),
        TranscriptWord(id: 3, text: "uh", start: 1.1, end: 1.3),
        TranscriptWord(id: 4, text: "works.", start: 3.5, end: 3.9),
        TranscriptWord(id: 5, text: "Um", start: 4.0, end: 4.2),
    ]

    func testNoSuggestionsMeansNoRows() {
        var edits = EditList(sourceDuration: 10)
        edits.add(cut(1, 2, Cut.Reason.word, .accepted))
        XCTAssertTrue(ChangeSummary.groups(edits: edits, words: words).isEmpty)
    }

    func testFillersAndPausesGetTheirOwnRows() {
        let edits = EditList(sourceDuration: 10, cuts: [
            cut(0, 0.45, Cut.Reason.filler),
            cut(1.05, 1.35, Cut.Reason.filler),
            cut(3.95, 4.25, Cut.Reason.filler),
            cut(1.5, 3.3, Cut.Reason.pause),
        ])
        let groups = ChangeSummary.groups(edits: edits, words: words)
        XCTAssertEqual(groups.map(\.kind), [.fillers, .pauses])

        let fillers = groups[0]
        XCTAssertEqual(fillers.title, "Removed 3 fillers")
        XCTAssertEqual(fillers.state, .proposed)
        XCTAssertTrue(fillers.detail.hasPrefix("“um”, “uh”"), fillers.detail)
        XCTAssertEqual(fillers.removedSeconds, 0.45 + 0.3 + 0.3, accuracy: 1e-9)

        let pauses = groups[1]
        XCTAssertEqual(pauses.title, "Cut 1 long pause")
        XCTAssertEqual(pauses.detail, "over 2.2 s · −2 s")
    }

    func testRowStateFollowsTheCuts() {
        var edits = EditList(sourceDuration: 10, cuts: [
            cut(0, 0.4, Cut.Reason.filler, .accepted),
            cut(1.1, 1.3, Cut.Reason.filler, .rejected),
        ])
        XCTAssertEqual(ChangeSummary.groups(edits: edits).first?.state, .accepted)
        XCTAssertEqual(ChangeSummary.groups(edits: edits).first?.count, 1)

        edits.setState(.rejected, forChange: .fillers)
        let off = ChangeSummary.groups(edits: edits).first
        XCTAssertEqual(off?.state, .off)
        XCTAssertEqual(off?.count, 2, "an off row still says how many it held")

        edits.setState(.accepted, forChange: .fillers)
        XCTAssertTrue(edits.cuts.allSatisfy { $0.state == .accepted })
        XCTAssertEqual(edits.outputDuration, 10 - 0.6, accuracy: 1e-9)
    }

    func testSwitchingOneRowLeavesTheOthers() {
        var edits = EditList(sourceDuration: 10, cuts: [
            cut(0, 0.4, Cut.Reason.filler),
            cut(2, 3, Cut.Reason.pause),
            cut(5, 6, Cut.Reason.trim),
            cut(7, 8, Cut.Reason.word, .accepted),
        ])
        edits.setState(.accepted, forChange: .pauses)
        XCTAssertEqual(edits.cuts.map(\.state), [.proposed, .accepted, .proposed, .accepted])
        let kinds = ChangeSummary.groups(edits: edits).map(\.kind)
        XCTAssertEqual(kinds, [.fillers, .pauses, .trims])
    }

    func testEffectRows() {
        let zooms = ZoomList(zooms: [
            Zoom(span: TimeSpan(start: 12, end: 15), scale: 1.4, centerX: 0.5, centerY: 0.5,
                 reason: Zoom.Reason.click, state: .proposed),
            Zoom(span: TimeSpan(start: 40, end: 43), scale: 1.4, centerX: 0.5, centerY: 0.5,
                 reason: Zoom.Reason.click, state: .accepted),
            Zoom(span: TimeSpan(start: 50, end: 53), scale: 1.4, centerX: 0.5, centerY: 0.5),
        ])
        let blurs = BlurList(blurs: [
            Blur(span: TimeSpan(start: 108, end: 110), rect: FrameRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
                 kind: "API key", reason: Blur.Reason.secret, state: .proposed),
        ])
        let sound = SoundPlan(effects: [
            PlacedEffect(soundID: "whoosh", at: 3, state: .proposed, isManual: false),
            PlacedEffect(soundID: "pop", at: 9, state: .proposed, isManual: false),
            PlacedEffect(soundID: "pop", at: 20, state: .accepted, isManual: true),
        ], energy: .lively)
        let groups = ChangeSummary.groups(edits: EditList(sourceDuration: 120), zooms: zooms, blurs: blurs, sound: sound)
        XCTAssertEqual(groups.map(\.kind), [.zooms, .blurs, .soundEffects])
        XCTAssertEqual(groups[0].title, "2 zooms on clicks")
        XCTAssertEqual(groups[0].detail, "at 0:12, 0:40")
        XCTAssertEqual(groups[0].state, .proposed)
        XCTAssertEqual(groups[1].title, "Blurred 1 API key")
        XCTAssertEqual(groups[1].detail, "at 1:48")
        XCTAssertEqual(groups[2].title, "2 sound effects")
        XCTAssertEqual(groups[2].detail, "whoosh, pop · energy Lively")
    }

    func testEffectRowSwitches() {
        var zooms = ZoomList(zooms: [
            Zoom(span: TimeSpan(start: 1, end: 3), scale: 1.4, centerX: 0.5, centerY: 0.5,
                 reason: Zoom.Reason.click, state: .proposed),
            Zoom(span: TimeSpan(start: 5, end: 7), scale: 1.4, centerX: 0.5, centerY: 0.5),
        ])
        zooms.setState(.rejected, forChange: .zooms)
        XCTAssertEqual(zooms.zooms.map(\.state), [.rejected, .accepted], "your own zoom isn't a suggestion")
        zooms.setState(.accepted, forChange: .blurs)
        XCTAssertEqual(zooms.zooms.map(\.state), [.rejected, .accepted])

        var sound = SoundPlan(effects: [
            PlacedEffect(soundID: "whoosh", at: 3, state: .proposed, isManual: false),
            PlacedEffect(soundID: "pop", at: 9, state: .accepted, isManual: true),
        ])
        sound.setState(.accepted, forChange: .soundEffects)
        XCTAssertEqual(sound.effects.map(\.state), [.accepted, .accepted])
        sound.rejectAllEffects()
        XCTAssertEqual(sound.effects.map(\.state), [.rejected, .rejected])
    }

    func testRevertAllGoesBackToTheRecording() {
        var edits = EditList(sourceDuration: 10, cuts: [
            cut(0, 0.4, Cut.Reason.filler, .accepted),
            cut(2, 3, Cut.Reason.pause),
            cut(5, 6, Cut.Reason.word, .accepted),
            cut(7, 8, Cut.Reason.trim, .rejected),
        ])
        edits.revertAll()
        XCTAssertEqual(edits.outputDuration, 10)
        XCTAssertEqual(edits.cuts.count, 3, "your own cut goes; suggestions stay, rejected")
        XCTAssertTrue(edits.cuts.allSatisfy { $0.state == .rejected })
    }

    func testMergedDurationCountsOverlapsOnce() {
        let spans = [TimeSpan(start: 0, end: 2), TimeSpan(start: 1, end: 3), TimeSpan(start: 5, end: 6)]
        XCTAssertEqual(ChangeSummary.mergedDuration(spans), 4, accuracy: 1e-9)
        XCTAssertEqual(ChangeSummary.seconds(0.44), "0.4")
        XCTAssertEqual(ChangeSummary.seconds(6.6), "7")
    }
}

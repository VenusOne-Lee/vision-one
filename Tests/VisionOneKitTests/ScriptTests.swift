import XCTest
@testable import VisionOneKit

final class ScriptTests: XCTestCase {
    let text = """
    Joburg taxi ranks, without the queue. Pick your rank.
    See exactly where the queue is. Pay with SnapScan before you get there.
    New in v0.4: live queue counts!
    """

    func testSplitsIntoSentencesAndKeepsVersionNumbers() {
        let script = Script(text: text)
        XCTAssertEqual(script.lines.map(\.text), [
            "Joburg taxi ranks, without the queue.",
            "Pick your rank.",
            "See exactly where the queue is.",
            "Pay with SnapScan before you get there.",
            "New in v0.4: live queue counts!",
        ])
        XCTAssertEqual(script.lines[1].words, ["pick", "your", "rank"])
        XCTAssertEqual(script.lines[4].words, ["new", "in", "v0.4", "live", "queue", "counts"])
        XCTAssertEqual(script.wordCount, 28)
        XCTAssertEqual(script.estimatedSeconds(wordsPerMinute: 120), 14, accuracy: 0.001)
    }

    func testAudioTagsAreNotWordsOrShown() {
        let script = Script(text: "[upbeat] Pick your rank. [pause] See the queue.")
        XCTAssertEqual(script.lines.map(\.text), ["Pick your rank.", "See the queue."])
        XCTAssertEqual(script.wordCount, 6)
    }

    func testBlankScriptHasNoLines() {
        XCTAssertTrue(Script(text: " \n  \n").isEmpty)
    }

    func testRoundTripsThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Script(text: text).write(to: url)
        XCTAssertEqual(try Script.read(from: url), Script(text: text))
    }
}

final class ScriptFollowerTests: XCTestCase {
    let script = Script(text: "Joburg taxi ranks, without the queue. Pick your rank. See exactly where the queue is.")

    func testFollowsInOrderAndSkipsAMissedWord() {
        var follower = ScriptFollower(script: script)
        for word in ["Joburg", "taxi", "ranks", "the", "queue"] { follower.hear(word) } // "without" missed
        XCTAssertEqual(follower.currentLine, 1)
        follower.hear("pick")
        XCTAssertEqual(follower.position, 7)
    }

    func testIgnoresFillers() {
        var follower = ScriptFollower(script: script)
        follower.hear("Joburg")
        XCTAssertNil(follower.hear("um"))
        XCTAssertEqual(follower.position, 1)
    }

    func testSayingALineAgainJumpsBack() {
        var follower = ScriptFollower(script: script)
        for word in "Joburg taxi ranks without the queue pick your rank".split(separator: " ") {
            follower.hear(String(word))
        }
        XCTAssertEqual(follower.currentLine, 2)
        XCTAssertEqual(follower.hear("Pick"), 6)
        XCTAssertEqual(follower.currentLine, 1)
    }

    func testACommonWordAloneDoesNotJump() {
        var follower = ScriptFollower(script: script)
        for word in "Joburg taxi ranks without the queue pick your rank see".split(separator: " ") {
            follower.hear(String(word))
        }
        let before = follower.position
        XCTAssertNil(follower.hear("the"))
        XCTAssertEqual(follower.position, before)
    }
}

final class ScriptTakesTests: XCTestCase {
    let script = Script(text: "Pick your rank. See exactly where the queue is.")

    /// Words half a second apart from `start`.
    private func words(_ text: String, from start: Double = 0) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { i, word in
            TranscriptWord(id: i, text: String(word), start: start + Double(i) * 0.5, end: start + Double(i) * 0.5 + 0.4)
        }
    }

    func testKeepsTheCompleteAttemptAndCutsTheFluff() {
        // "Pick your um" (fluff), then "pick your rank", then line 2.
        let spoken = words("Pick your um pick your rank see exactly where the queue is")
        let takes = ScriptTakes.find(script: script, words: spoken)
        XCTAssertEqual(takes.lines[0].attempts.count, 2)
        XCTAssertEqual(takes.lines[0].kept, 1)
        XCTAssertEqual(takes.lines[0].attempts[0].coverage, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(takes.lines[0].attempts[0].strays, 1)
        XCTAssertEqual(takes.lines[1].attempts.count, 1)
        XCTAssertEqual(takes.retakenLines.count, 1)

        let cuts = takes.cuts(endOfTake: 10)
        XCTAssertEqual(cuts.count, 1)
        // From the first "Pick" to the second "pick", so the um goes too.
        XCTAssertEqual(cuts[0].span, TimeSpan(start: 0, end: 1.5))
        XCTAssertEqual(cuts[0].state, .proposed)
        XCTAssertEqual(cuts[0].reason, Cut.Reason.`repeat`)
    }

    func testTwoCompleteAttemptsKeepTheLaterOne() {
        let spoken = words("pick your rank pick your rank")
        let takes = ScriptTakes.find(script: script, words: spoken)
        XCTAssertEqual(takes.lines[0].attempts.count, 2)
        XCTAssertEqual(takes.lines[0].kept, 1)
    }

    func testCleanerAttemptBeatsALaterOneWithStrays() {
        let spoken = words("pick your rank pick um your uh rank")
        let takes = ScriptTakes.find(script: script, words: spoken)
        XCTAssertEqual(takes.lines[0].kept, 0)
        let cuts = takes.cuts(endOfTake: 10)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start, 1.5, accuracy: 0.001)
    }

    func testLineNeverSaidKeepsNothing() {
        let takes = ScriptTakes.find(script: script, words: words("pick your rank"))
        XCTAssertNil(takes.lines[1].kept)
        XCTAssertTrue(takes.cuts(endOfTake: 5).isEmpty)
    }
}

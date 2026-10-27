import XCTest
@testable import VisionOneKit

final class EmptyStateTests: XCTestCase {
    func testChangesWhileTranscribing() {
        let state = ChangesEmptyState.resolve(hasTranscript: false, failure: nil)
        XCTAssertEqual(state, .transcribing)
        XCTAssertFalse(state.isError)
    }

    func testChangesWithTranscriptAndNothingSuggested() {
        XCTAssertEqual(ChangesEmptyState.resolve(hasTranscript: true, failure: nil), .noSuggestions)
        // A transcript that landed wins over an old failure.
        XCTAssertEqual(ChangesEmptyState.resolve(hasTranscript: true, failure: "No sound"), .noSuggestions)
        XCTAssertFalse(ChangesEmptyState.noSuggestions.message.contains("once the transcript is written"))
    }

    func testChangesWithNoTranscript() {
        let state = ChangesEmptyState.resolve(hasTranscript: false, failure: "  This take has no sound.  ")
        XCTAssertEqual(state, .noTranscript(reason: "This take has no sound."))
        XCTAssertEqual(state.message, "This take has no sound.")
        XCTAssertTrue(state.isError)
        // A blank reason still says something useful.
        let blank = ChangesEmptyState.resolve(hasTranscript: false, failure: " ")
        XCTAssertEqual(blank, .noTranscript(reason: nil))
        XCTAssertFalse(blank.message.isEmpty)
    }

    func testAINoticeOnlyWhenCheckedAndNothingReady() {
        XCTAssertFalse(AISetupNotice.isShown(anyRungReady: nil, dismissed: false))
        XCTAssertFalse(AISetupNotice.isShown(anyRungReady: true, dismissed: false))
        XCTAssertTrue(AISetupNotice.isShown(anyRungReady: false, dismissed: false))
        XCTAssertFalse(AISetupNotice.isShown(anyRungReady: false, dismissed: true))
    }

    func testTranscriptPreview() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-27 10.00.00"))
        func listing(_ text: String?) -> TakeListing { TakeListing(take: take, title: "Demo", transcriptText: text) }

        XCTAssertNil(listing(nil).transcriptPreview())
        XCTAssertNil(listing(" \n ").transcriptPreview())
        XCTAssertEqual(listing("  Hi there,\n\nthis is   the demo. ").transcriptPreview(), "Hi there, this is the demo.")

        let long = listing("one two three four five six").transcriptPreview(maxLength: 12)
        XCTAssertEqual(long, "one two…")
        XCTAssertLessThanOrEqual(long?.count ?? 0, 12)

        // One very long word is cut mid-word rather than dropped.
        XCTAssertEqual(listing("abcdefghijklmnop").transcriptPreview(maxLength: 6), "abcde…")
    }
}

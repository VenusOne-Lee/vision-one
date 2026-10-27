import XCTest
@testable import VisionOneKit

final class PostApprovalTests: XCTestCase {
    func testNumbersMapToTheThreeAnswers() {
        XCTAssertEqual(ApprovalAnswer(number: 1), .yes)
        XCTAssertEqual(ApprovalAnswer(number: 2), .yesAlways)
        XCTAssertEqual(ApprovalAnswer(number: 3, feedback: "shorter"), .no(feedback: "shorter"))
        XCTAssertNil(ApprovalAnswer(number: 4))
        XCTAssertTrue(ApprovalAnswer.yesAlways.isYes)
        XCTAssertFalse(ApprovalAnswer.no(feedback: "").isYes)
    }

    func testArrowsStopAtTheEnds() {
        var selection = ApprovalSelection(count: 3)
        selection.up()
        XCTAssertEqual(selection.number, 1)
        selection.down(); selection.down(); selection.down()
        XCTAssertEqual(selection.number, 3)
        XCTAssertTrue(selection.pick(2))
        XCTAssertEqual(selection.index, 1)
        XCTAssertFalse(selection.pick(4))
        XCTAssertFalse(selection.pick(0))
        XCTAssertEqual(selection.index, 1)
    }

    func testRulesAreForOneProductAndOnePlace() throws {
        var rules = PostRules()
        rules.allow(scope: " RankRide ", destination: "VersionOne.co.za")
        XCTAssertTrue(rules.allows(scope: "rankride", destination: "versionone.co.za"))
        XCTAssertFalse(rules.allows(scope: "rankride", destination: "x.com"))
        XCTAssertFalse(rules.allows(scope: "Other", destination: "versionone.co.za"))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("post-rules.json")
        try rules.write(to: url)
        XCTAssertEqual(PostRules.load(from: url), rules)

        rules.forget(scope: "RankRide", destination: "versionone.co.za")
        XCTAssertFalse(rules.allows(scope: "RankRide", destination: "versionone.co.za"))
        XCTAssertEqual(PostRules.load(from: url.appendingPathExtension("missing")), PostRules())
    }

    func testCardWordsNameTheProduct() {
        XCTAssertEqual(PostApprovalText.question(to: "Version One"), "Post this to Version One?")
        XCTAssertEqual(PostApprovalText.options(scope: "RankRide")[1], "Yes, and don't ask again for RankRide posts")
        XCTAssertEqual(PostApprovalText.options(scope: "")[1], "Yes, and don't ask again for these posts")
        XCTAssertEqual(PostApprovalText.options(scope: "x").count, 3)
    }

    func testLaunchPostTextSkipsEmptyLines() {
        let launch = SharePack.Launch(name: "RankRide", oneLine: "Skip the queue at Joburg taxi ranks.",
                                      whoItsFor: "commuters", whatsNew: " ")
        XCTAssertEqual(launch.postText, "RankRide\nSkip the queue at Joburg taxi ranks.\nFor: commuters")
    }
}

import XCTest
@testable import VisionOneKit

final class WorkspaceRoutingTests: XCTestCase {
    func testNavigationDoesNotLaunchEditing() {
        for (ask, command) in [("Start recording", "record"), ("Add captions", "captions"),
                               ("Open sound", "sound"), ("Review changes", "review")] {
            XCTAssertEqual(AskRouter.route(ask), .open(command))
        }
    }
    func testCompoundAskStillCreatesPlan() {
        guard case let .plan(plan) = AskRouter.route("Remove pauses and make 3 clips") else {
            return XCTFail("A compound content request needs a plan")
        }
        XCTAssertEqual(plan.steps.count, 2)
    }
}

extension WorkspaceRoutingTests {
    func testAmbiguousRequestDoesNotRunAnUnrelatedEdit() {
        for ask in ["", "help", "do something", "hello", "what can you do?"] {
            guard case .clarify = AskRouter.route(ask) else { return XCTFail("Unexpected action for \(ask)") }
        }
        XCTAssertEqual(AskRouter.route("Import a video"), .open("import"))
    }
}

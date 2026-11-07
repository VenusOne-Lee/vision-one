import XCTest
@testable import VisionOneKit

final class PhoneTrackTests: XCTestCase {
    private let frame = CaptureRect(x: 0, y: 0, width: 1920, height: 1080)

    func testPhoneTimeFollowsTheOffset() {
        let track = PhoneTrack(deviceName: "iPhone", startOffset: 0.4)
        XCTAssertEqual(track.phoneTime(forScreen: 10), 9.6, accuracy: 1e-9)
        let early = PhoneTrack(deviceName: "iPhone", startOffset: -0.25)
        XCTAssertEqual(early.phoneTime(forScreen: 1), 1.25, accuracy: 1e-9)
    }

    func testUprightPhoneSitsOnTheRightCentred() {
        let rect = PhoneTrack.frame(aspect: 9.0 / 19.5, in: frame)
        XCTAssertEqual(rect.height, 1080 * 0.72, accuracy: 1e-6)
        XCTAssertEqual(rect.width, rect.height * 9 / 19.5, accuracy: 1e-6)
        XCTAssertEqual(rect.x + rect.width, 1920 - 1080 * 0.04, accuracy: 1e-6)
        XCTAssertEqual(rect.y + rect.height / 2, 540, accuracy: 1e-6)
    }

    func testSidewaysPhoneIsKeptNarrowEnough() {
        let rect = PhoneTrack.frame(aspect: 19.5 / 9.0, in: frame)
        XCTAssertLessThanOrEqual(rect.width, 1920 * 0.45 + 1e-6)
        XCTAssertEqual(rect.width / rect.height, 19.5 / 9.0, accuracy: 1e-6)
    }

    func testEmptyFrameGivesNothing() {
        let rect = PhoneTrack.frame(aspect: 0.5, in: CaptureRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(rect.width, 0)
    }

    func testRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let track = PhoneTrack(deviceName: "Lee's iPhone", startOffset: 0.31)
        try track.write(to: url)
        XCTAssertEqual(try PhoneTrack.read(from: url), track)
    }
}

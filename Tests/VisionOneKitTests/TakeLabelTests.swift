import XCTest
@testable import VisionOneKit

final class TakeLabelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Johannesburg")!
        return calendar
    }

    private func take(_ name: String) -> Take {
        Take(folder: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true))
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    func testReadsTheDateBackFromTheName() {
        let recorded = take("Vision One 2026-10-27 at 14.41.05 (2)").recordedAt(timeZone: calendar.timeZone)
        XCTAssertEqual(recorded, date("2026-10-27T12:41:05Z"))
        XCTAssertNil(take("Holiday clips").recordedAt())
    }

    func testShortLabels() {
        let now = date("2026-10-27T15:00:00Z")
        XCTAssertEqual(take("Vision One 2026-10-27 at 14.41.05").shortLabel(now: now, calendar: calendar), "Today at 14:41")
        XCTAssertEqual(take("Vision One 2026-10-26 at 09.05.00").shortLabel(now: now, calendar: calendar), "Yesterday at 09:05")
        XCTAssertEqual(take("Vision One 2026-10-02 at 18.30.00").shortLabel(now: now, calendar: calendar), "2 Oct at 18:30")
        XCTAssertEqual(take("Holiday clips").shortLabel(now: now, calendar: calendar), "Holiday clips")
    }

    func testShortTimecode() {
        XCTAssertEqual(Timecode.short(from: 7.9), "0:07")
        XCTAssertEqual(Timecode.short(from: 133), "2:13")
        XCTAssertEqual(Timecode.short(from: 3733), "1:02:13")
    }
}

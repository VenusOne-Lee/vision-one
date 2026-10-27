import XCTest
@testable import VisionOneKit

final class TimecodeTests: XCTestCase {
    func testFormatsHoursMinutesSeconds() {
        XCTAssertEqual(Timecode.string(from: 0), "00:00:00")
        XCTAssertEqual(Timecode.string(from: 167.9), "00:02:47")
        XCTAssertEqual(Timecode.string(from: 3725), "01:02:05")
    }

    func testNegativeIsZero() {
        XCTAssertEqual(Timecode.string(from: -4), "00:00:00")
    }
}

final class RecordingPhaseTests: XCTestCase {
    func testOnlyRecordingIsLive() {
        XCTAssertTrue(RecordingPhase.recording(startedAt: Date()).isLive)
        for phase: RecordingPhase in [.idle, .preparing, .finishing, .failed(message: "x")] {
            XCTAssertFalse(phase.isLive, "\(phase) must not be live")
        }
    }

    func testElapsed() {
        let start = Date(timeIntervalSince1970: 1000)
        let phase = RecordingPhase.recording(startedAt: start)
        XCTAssertEqual(phase.elapsed(at: start.addingTimeInterval(12)), 12)
        XCTAssertNil(RecordingPhase.idle.elapsed())
    }
}

final class TakeLibraryTests: XCTestCase {
    func testTakeName() {
        let date = Date(timeIntervalSince1970: 1_793_098_392) // 2026-10-27 10:53:12 UTC
        let name = TakeLibrary.takeName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "Vision One 2026-10-27 at 10.53.12")
    }

    func testTakeFiles() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One x", isDirectory: true))
        XCTAssertEqual(take.screenURL.lastPathComponent, "screen.mov")
        XCTAssertEqual(take.eventsURL.lastPathComponent, "events.json")
        XCTAssertEqual(take.cameraURL.lastPathComponent, "camera.mov")
        XCTAssertEqual(take.transcriptURL.lastPathComponent, "transcript.json")
    }

    func testDoesNotReuseAFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TakeLibrary(folder: root)
        let date = Date()

        let first = try library.newTake(at: date)
        let second = try library.newTake(at: date)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.name.hasSuffix(" (2)"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}

final class EventLogTests: XCTestCase {
    func testThinsMovesButKeepsClicks() {
        var log = EventLog(displayWidth: 1512, displayHeight: 982)
        log.append(InputEvent(kind: .move, t: 0.000, x: 1, y: 1))
        log.append(InputEvent(kind: .move, t: 0.005, x: 2, y: 2)) // too soon, dropped
        log.append(InputEvent(kind: .leftDown, t: 0.006, x: 2, y: 2))
        log.append(InputEvent(kind: .move, t: 0.030, x: 3, y: 3))
        XCTAssertEqual(log.events.map(\.kind), [.move, .leftDown, .move])
    }

    func testDropsEventsBeforeFirstFrame() {
        var log = EventLog(displayWidth: 100, displayHeight: 100)
        log.append(InputEvent(kind: .leftDown, t: -0.5, x: 0, y: 0))
        XCTAssertTrue(log.events.isEmpty)
    }

    func testRoundTrips() throws {
        var log = EventLog(displayWidth: 100, displayHeight: 50)
        log.append(InputEvent(kind: .leftDown, t: 1.25, x: 10, y: 20))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try log.write(to: url)
        let decoded = try JSONDecoder().decode(EventLog.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded, log)
    }
}

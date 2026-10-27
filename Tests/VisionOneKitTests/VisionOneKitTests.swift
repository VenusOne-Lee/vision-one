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

final class RecordingLibraryTests: XCTestCase {
    func testFileName() {
        let date = Date(timeIntervalSince1970: 1_793_098_392) // 2026-10-27 10:53:12 UTC
        let name = RecordingLibrary.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "Vision One 2026-10-27 at 10.53.12.mp4")
    }

    func testDoesNotOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = RecordingLibrary(folder: folder)
        let date = Date()

        let first = try library.newRecordingURL(at: date)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = try library.newRecordingURL(at: date)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" (2).mp4"))
    }
}

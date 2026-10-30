import XCTest
@testable import VisionOneKit

final class RecordedMixTests: XCTestCase {
    func testSavedMixKeepsSourcesSeparateAndBoundsGain() throws {
        let mix = RecordedMix(voiceDB: -6, systemDB: -60)
        XCTAssertEqual(mix.gain(isMicrophone: true), 0.5012, accuracy: 0.001)
        XCTAssertEqual(mix.gain(isMicrophone: false), 0.001, accuracy: 0.00001)
        XCTAssertEqual(RecordedMix(voiceDB: .nan).gain(isMicrophone: true), 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let take = Take(folder: root)
        try mix.write(for: take)
        XCTAssertEqual(RecordedMix.load(for: take), mix)
    }
}

extension RecordedMixTests {
    func testPortraitOutputKeepsFourByFiveTemplateShape() throws {
        let settings = try ExportPlanner.settings(for: .portrait,
            source: ExportSource(width: 1920, height: 1080, frameRate: 30), duration: 3)
        XCTAssertEqual(settings.width, 1080)
        XCTAssertEqual(settings.height, 1350)
    }
}

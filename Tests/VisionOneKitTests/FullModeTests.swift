import XCTest
@testable import VisionOneKit

final class EditorToolTests: XCTestCase {
    func testKeysPickTools() {
        XCTAssertEqual(EditorTool.forKey("v"), .select)
        XCTAssertEqual(EditorTool.forKey("C"), .cut)
        XCTAssertEqual(EditorTool.forKey("z"), .zoom)
        XCTAssertEqual(EditorTool.forKey("b"), .blur)
        XCTAssertNil(EditorTool.forKey("q"))
    }

    func testDrawnSpanStopsAtTheEnd() {
        XCTAssertEqual(EditorTool.drawnSpan(at: 10, sourceDuration: 60), TimeSpan(start: 10, end: 13))
        XCTAssertEqual(EditorTool.drawnSpan(at: 59, sourceDuration: 60), TimeSpan(start: 59, end: 60))
        XCTAssertNil(EditorTool.drawnSpan(at: 59.9, sourceDuration: 60))
    }
}

final class LaneMixTests: XCTestCase {
    func testEverythingPlaysByDefault() {
        let mix = LaneMix()
        XCTAssertTrue(MixLane.allCases.allSatisfy(mix.isAudible))
        XCTAssertTrue(mix.isDefault)
    }

    func testMuteSilencesOneLane() {
        var mix = LaneMix()
        mix.toggleMute(.music)
        XCTAssertFalse(mix.isAudible(.music))
        XCTAssertTrue(mix.isAudible(.voice))
        mix.toggleMute(.music)
        XCTAssertTrue(mix.isDefault)
    }

    func testSoloWinsOverMute() {
        var mix = LaneMix()
        mix.toggleMute(.voice)
        mix.toggleSolo(.voice)
        XCTAssertTrue(mix.isAudible(.voice))
        XCTAssertFalse(mix.isAudible(.music))
        XCTAssertFalse(mix.isAudible(.effects))
    }
}

final class IntegratedLoudnessTests: XCTestCase {
    func testSteadyLevelReadsAsItself() throws {
        let envelope = LoudnessEnvelope(hop: 0.01, levels: Array(repeating: -16, count: 1000))
        let lufs = try XCTUnwrap(envelope.integratedLoudness())
        XCTAssertEqual(lufs, -16, accuracy: 0.01)
    }

    func testSilenceIsGatedOut() throws {
        // Ten seconds of speech at -18, ten of near silence: the gate
        // keeps only the speech.
        let levels = Array(repeating: Float(-18), count: 1000) + Array(repeating: Float(-90), count: 1000)
        let lufs = try XCTUnwrap(LoudnessEnvelope(hop: 0.01, levels: levels).integratedLoudness())
        XCTAssertEqual(lufs, -18, accuracy: 0.5)
    }

    func testAllSilentHasNoLoudness() {
        XCTAssertNil(LoudnessEnvelope(hop: 0.01, levels: Array(repeating: -95, count: 500)).integratedLoudness())
    }

    func testVerdicts() {
        XCTAssertEqual(LoudnessTarget.verdict(lufs: -14), "good for YouTube")
        XCTAssertEqual(LoudnessTarget.verdict(lufs: -24), "quiet, platforms will turn it up")
    }
}

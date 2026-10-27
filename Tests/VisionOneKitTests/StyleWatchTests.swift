import XCTest
@testable import VisionOneKit

final class StyleWatchTests: XCTestCase {
    private func state(_ time: Double, duration: Double = 30, ended: Bool = false) -> StyleWatch.VideoState {
        StyleWatch.VideoState(found: true, playing: !ended, ended: ended, time: time, duration: duration,
                              width: 1080, height: 1920, x: 0, y: 0, w: 400, h: 711)
    }

    func testParsesTheScriptReply() {
        let reply = #"{"found":true,"playing":true,"ended":false,"time":3.5,"duration":null,"width":1080,"height":1920,"x":10,"y":20,"w":300,"h":533}"#
        let parsed = StyleWatch.VideoState.parse(reply)
        XCTAssertTrue(parsed.found)
        XCTAssertTrue(parsed.playing)
        XCTAssertEqual(parsed.time, 3.5)
        XCTAssertEqual(parsed.duration, 0)
        XCTAssertEqual(parsed.h, 533)
    }

    func testAnythingElseIsNotFound() {
        XCTAssertFalse(StyleWatch.VideoState.parse(nil).found)
        XCTAssertFalse(StyleWatch.VideoState.parse(42).found)
        XCTAssertFalse(StyleWatch.VideoState.parse("not json").found)
        XCTAssertFalse(StyleWatch.VideoState.parse(#"{"found":false}"#).found)
    }

    func testPictureSkipsTheBars() {
        // A vertical video in a wide box: bars left and right.
        let wide = StyleWatch.VideoState(found: true, width: 1080, height: 1920, x: 0, y: 0, w: 1000, h: 640)
        let picture = wide.pictureRect
        XCTAssertEqual(picture.height, 640)
        XCTAssertEqual(picture.width, 360, accuracy: 0.01)
        XCTAssertEqual(picture.x, 320, accuracy: 0.01)

        // A landscape video in a tall box: bars top and bottom.
        let tall = StyleWatch.VideoState(found: true, width: 1920, height: 1080, x: 10, y: 0, w: 320, h: 600)
        XCTAssertEqual(tall.pictureRect.height, 180, accuracy: 0.01)
        XCTAssertEqual(tall.pictureRect.y, 210, accuracy: 0.01)
        XCTAssertEqual(tall.pictureRect.x, 10)
    }

    func testStopsAtTheEnd() {
        var progress = StyleWatch.Progress()
        XCTAssertFalse(progress.update(state(0)))
        XCTAssertFalse(progress.update(state(15)))
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.01)
        XCTAssertTrue(progress.update(state(29.8)))
    }

    func testStopsWhenEnded() {
        var progress = StyleWatch.Progress()
        progress.update(state(10))
        XCTAssertTrue(progress.update(state(12, ended: true)))
    }

    func testStopsWhenItLoops() {
        var progress = StyleWatch.Progress()
        progress.update(state(5, duration: 0))
        progress.update(state(14, duration: 0))
        XCTAssertTrue(progress.update(state(0.3, duration: 0)))
        XCTAssertEqual(progress.furthest, 14)
    }

    func testAShortSeekBackIsNotALoop() {
        var progress = StyleWatch.Progress()
        progress.update(state(1))
        XCTAssertFalse(progress.update(state(0.5)))
    }

    func testLongVideosStopAtTheCap() {
        var progress = StyleWatch.Progress()
        progress.update(state(0, duration: 900))
        XCTAssertEqual(progress.target, StyleMeasure.maxSeconds)
        XCTAssertTrue(progress.update(state(StyleMeasure.maxSeconds, duration: 900)))
    }

    func testMissingVideoChangesNothing() {
        var progress = StyleWatch.Progress()
        XCTAssertFalse(progress.update(StyleWatch.VideoState(found: false)))
        XCTAssertEqual(progress.furthest, 0)
    }

    func testScriptsAreSelfContained() {
        XCTAssertTrue(StyleWatch.probeScript.hasPrefix("(() => {"))
        XCTAssertTrue(StyleWatch.probeScript.contains("JSON.stringify"))
        XCTAssertTrue(StyleWatch.playScript.contains("v.play()"))
    }

    func testUnheardSoundIsNotCopiedAsNoMusic() {
        let frames = StyleMeasure.sampleTimes(duration: 20).map { t in
            StyleFrame(time: t, signature: [1, 0], faces: [], text: [])
        }
        let profile = StyleScanner.profile(from: StyleInput(duration: 20, width: 1080, height: 1920, frames: frames),
                                           source: "TikTok")
        let music = profile.traits.first { $0.id == .music }
        XCTAssertEqual(music?.value, "Sound not heard")
        XCTAssertEqual(music?.copiedByDefault, false)
        XCTAssertNil(CopiedStyle(profile: profile).wantsMusic)
    }
}

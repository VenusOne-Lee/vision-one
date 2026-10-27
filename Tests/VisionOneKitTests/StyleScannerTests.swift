import XCTest
@testable import VisionOneKit

final class StyleScannerTests: XCTestCase {
    // MARK: - Helpers

    /// A signature with all its weight in one bin, so two shots with
    /// different bins differ completely.
    private func signature(_ bin: Int, noise: Double = 0) -> [Double] {
        var s = [Double](repeating: 0, count: 8)
        s[bin % 8] = 1 - noise
        s[(bin + 1) % 8] += noise
        return s
    }

    /// 4 frames a second, a new shot every `shot` seconds, Vision on one
    /// frame in four.
    private func frames(duration: Double, shot: Double, faces: ((Double, Int) -> [NormalisedRect])? = nil,
                        text: ((Double) -> [StyleTextBox])? = nil, colours: [StyleRGB] = []) -> [StyleFrame] {
        StyleMeasure.sampleTimes(duration: duration).enumerated().map { i, t in
            let shotIndex = Int(t / shot)
            let read = StyleMeasure.readsVision(at: i)
            return StyleFrame(time: t, signature: signature(shotIndex, noise: (i % 3 == 0) ? 0.05 : 0),
                              colours: colours,
                              faces: read ? (faces?(t, shotIndex) ?? []) : nil,
                              text: read ? (text?(t) ?? []) : nil)
        }
    }

    private func box(_ text: String, y: Double = 0.7, width: Double = 0.5) -> StyleTextBox {
        StyleTextBox(rect: NormalisedRect(x: 0.25, y: y - 0.03, width: width, height: 0.06), text: text)
    }

    // MARK: - Cuts

    func testFindsEveryCutAndNothingElse() {
        let f = frames(duration: 30, shot: 2)
        let cuts = StyleScanner.cuts(in: f)
        XCTAssertEqual(cuts.count, 14)
        for (i, cut) in cuts.enumerated() {
            XCTAssertEqual(cut, Double(i + 1) * 2, accuracy: 0.26)
        }
    }

    func testBusyFootageIsNotCuts() {
        // Every frame changes a bit: no single frame stands out.
        let f = (0..<120).map { i -> StyleFrame in
            var s = [Double](repeating: 0.1, count: 10)
            s[i % 10] += 0.35
            let total = s.reduce(0, +)
            return StyleFrame(time: Double(i) / 4, signature: s.map { $0 / total })
        }
        XCTAssertEqual(StyleScanner.cuts(in: f), [])
    }

    func testDifferenceIsHalfL1() {
        XCTAssertEqual(StyleScanner.difference([1, 0], [0, 1]), 1)
        XCTAssertEqual(StyleScanner.difference([0.5, 0.5], [0.5, 0.5]), 0)
        XCTAssertEqual(StyleScanner.difference([1], [0.5, 0.5]), 1)
    }

    func testPaceFromShotLength() {
        XCTAssertEqual(StylePace.from(medianShot: 1), .rapid)
        XCTAssertEqual(StylePace.from(medianShot: 2), .fast)
        XCTAssertEqual(StylePace.from(medianShot: 4), .steady)
        XCTAssertEqual(StylePace.from(medianShot: 9), .slow)
    }

    // MARK: - Captions

    func testBoldPopCaptionsInTheMiddle() {
        let words = ["THIS", "SAVED ME", "HOURS", "EVERY DAY", "LOOK"]
        let f = frames(duration: 30, shot: 3, text: { t in [self.box(words[Int(t) % words.count], y: 0.6)] })
        let captions = StyleScanner.captions(in: f.filter { $0.text != nil }, duration: 30)
        XCTAssertEqual(captions?.style, .boldPop)
        XCTAssertEqual(captions?.uppercase, true)
        XCTAssertEqual(captions?.placement, .middle)
    }

    func testLongLowCaptionsAreSubtitles() {
        let lines = ["so today I want to show you how this works", "and why it matters for your small business"]
        let f = frames(duration: 30, shot: 5, text: { t in [self.box(lines[Int(t / 2) % 2], y: 0.86, width: 0.8)] })
        let captions = StyleScanner.captions(in: f.filter { $0.text != nil }, duration: 30)
        XCTAssertEqual(captions?.style, .subtitle)
        XCTAssertEqual(captions?.placement, .bottom)
        XCTAssertEqual(captions?.uppercase, false)
    }

    func testAStillTitleIsNotCaptions() {
        let f = frames(duration: 30, shot: 5, text: { _ in [self.box("Ledger Lite", y: 0.8)] })
        XCTAssertNil(StyleScanner.captions(in: f.filter { $0.text != nil }, duration: 30))
    }

    func testWordsAtTheTopAreNotCaptions() {
        let f = frames(duration: 30, shot: 5, text: { t in [self.box("Step \(Int(t))", y: 0.1)] })
        XCTAssertNil(StyleScanner.captions(in: f.filter { $0.text != nil }, duration: 30))
    }

    // MARK: - Framing

    func testTalkingHeadWithPunchIns() {
        // Every other shot is a tighter crop on the same face.
        let f = frames(duration: 40, shot: 2, faces: { _, shot in
            let size = shot % 2 == 0 ? 0.25 : 0.38
            return [NormalisedRect(centerX: 0.5, centerY: 0.4, width: size, height: size)]
        })
        let cuts = StyleScanner.cuts(in: f)
        let framing = StyleScanner.framing(in: f, cuts: cuts, duration: 40)
        XCTAssertEqual(framing.kind, .talkingHead)
        XCTAssertGreaterThan(framing.faceShare, 0.9)
        XCTAssertGreaterThanOrEqual(framing.punchInsPerMinute, 10)
    }

    func testSmallCornerFaceIsACameraBubble() {
        let f = frames(duration: 30, shot: 6, faces: { _, _ in
            [NormalisedRect(centerX: 0.88, centerY: 0.84, width: 0.1, height: 0.12)]
        })
        let framing = StyleScanner.framing(in: f, cuts: StyleScanner.cuts(in: f), duration: 30)
        XCTAssertEqual(framing.kind, .cameraBubble)
        XCTAssertEqual(framing.punchInsPerMinute, 0)
    }

    func testNoFacesIsScreen() {
        let f = frames(duration: 30, shot: 6)
        XCTAssertEqual(StyleScanner.framing(in: f, cuts: [], duration: 30).kind, .screen)
    }

    // MARK: - Colour

    func testPaletteFindsTheBigColoursFirst() {
        let dark = StyleRGB(hex: 0x101012), cream = StyleRGB(hex: 0xF2EDE4), gold = StyleRGB(hex: 0xE8C547)
        let cells = Array(repeating: dark, count: 10) + Array(repeating: cream, count: 4) + Array(repeating: gold, count: 2)
        let f = frames(duration: 10, shot: 5, colours: cells)
        let (palette, brightness) = StyleScanner.palette(from: f)
        XCTAssertEqual(palette.first?.hex, "#101012")
        XCTAssertEqual(palette.count, 3)
        XCTAssertEqual(palette.map(\.share).reduce(0, +), 1, accuracy: 0.02)
        XCTAssertLessThan(brightness, 0.5)
    }

    func testMeasuringPixels() {
        // 4×2 RGBA: left half red, right half blue.
        let red: [UInt8] = [255, 0, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
        let row = red + red + blue + blue
        let (signature, colours) = StyleMeasure.frame(pixels: row + row, width: 4, height: 2, bytesPerRow: 16)
        XCTAssertEqual(signature.count, 256)
        XCTAssertEqual(signature.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(colours.first?.hex, "#FF0000")
        XCTAssertEqual(colours.last?.hex, "#0000FF")

        let (bgraSignature, bgraColours) = StyleMeasure.frame(pixels: row + row, width: 4, height: 2, bytesPerRow: 16, bgra: true)
        XCTAssertEqual(bgraColours.first?.hex, "#0000FF")
        XCTAssertEqual(StyleScanner.difference(signature, bgraSignature), 1)
    }

    // MARK: - Sound

    func testTempoFromAPulse() {
        // 120 bpm: a beat every 0.5 s, envelope at 20 a second.
        let envelope = (0..<400).map { i in i % 10 == 0 ? 1.0 : 0.1 }
        let bpm = StyleScanner.tempo(envelope: envelope, rate: 20)
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm ?? 0, 120, accuracy: 4)
    }

    func testNoBeatInNoise() {
        var seed: UInt64 = 42
        let envelope = (0..<400).map { _ -> Double in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        XCTAssertNil(StyleScanner.tempo(envelope: envelope, rate: 20))
    }

    func testMusicUnderVoice() {
        var windows: [StyleSoundWindow] = []
        for i in 0..<30 {
            let talking = i >= 2
            windows.append(StyleSoundWindow(start: Double(i), duration: 1, speech: talking ? 0.9 : 0.1,
                                            music: 0.8, loudness: talking ? -14 : -32))
        }
        let music = StyleScanner.music(sound: windows, envelope: [], rate: 20)
        XCTAssertNotNil(music)
        XCTAssertEqual(music?.underVoiceDB, 18)
        XCTAssertNil(StyleScanner.music(sound: windows.map {
            StyleSoundWindow(start: $0.start, duration: 1, speech: 0.9, music: 0.1, loudness: -14)
        }, envelope: [], rate: 20))
    }

    // MARK: - Whole profile

    private func shortInput() -> StyleInput {
        let words = ["THIS", "SAVED ME", "HOURS", "EVERY DAY", "LOOK"]
        let f = frames(duration: 38, shot: 1.25, faces: { _, shot in
            let size = shot % 3 == 0 ? 0.3 : 0.42
            return [NormalisedRect(centerX: 0.5, centerY: 0.35, width: size, height: size)]
        }, text: { t in [self.box(words[Int(t * 2) % words.count], y: 0.62)] },
           colours: [StyleRGB(hex: 0x101012), StyleRGB(hex: 0xF2EDE4)])
        let sound = (0..<38).map { i in
            StyleSoundWindow(start: Double(i), duration: 1, speech: 0.9, music: 0.7, loudness: -14)
        }
        let envelope = (0..<(38 * 20)).map { i in i % 10 == 0 ? 1.0 : 0.1 }
        return StyleInput(duration: 38, width: 1080, height: 1920, frames: f, sound: sound, envelope: envelope)
    }

    func testFastTalkingShort() {
        let profile = StyleScanner.profile(from: shortInput(), source: "TikTok")
        XCTAssertEqual(profile.format, .vertical)
        XCTAssertEqual(profile.cuts.pace, .rapid)
        XCTAssertEqual(profile.captions?.style, .boldPop)
        XCTAssertEqual(profile.framing.kind, .talkingHead)
        XCTAssertEqual(profile.hook.kind, .talksFirst)
        XCTAssertNil(profile.intro)
        XCTAssertEqual(profile.energy, .viral)
        XCTAssertEqual(profile.purposeID, "short")
        XCTAssertEqual(profile.music?.bpm ?? 0, 120, accuracy: 4)
        XCTAssertEqual(profile.targetSeconds, 30...50)
        XCTAssertEqual(profile.suggestedTitle, "Rapid talking head short")
    }

    func testCalmScreenTutorialWithIntroCard() {
        // A 4 s title card with nobody talking, then long screen shots.
        let duration = 180.0
        let f = StyleMeasure.sampleTimes(duration: duration).enumerated().map { i, t -> StyleFrame in
            let shot = t < 4 ? 0 : 1 + Int((t - 4) / 20)
            let read = StyleMeasure.readsVision(at: i)
            return StyleFrame(time: t, signature: signature(shot), colours: [StyleRGB(hex: 0xFBFBFD)],
                              faces: read ? [] : nil,
                              text: read ? (t < 4 ? [box("Ledger Lite", y: 0.5)] : []) : nil)
        }
        let sound = stride(from: 0.0, to: duration, by: 1).map { t in
            StyleSoundWindow(start: t, duration: 1, speech: t < 4.5 ? 0 : 0.9, music: 0, loudness: -18)
        }
        let profile = StyleScanner.profile(from: StyleInput(duration: duration, width: 2880, height: 1800,
                                                            frames: f, sound: sound), source: "demo.mov")
        XCTAssertEqual(profile.format, .landscape)
        XCTAssertEqual(profile.cuts.pace, .slow)
        XCTAssertEqual(profile.intro ?? 0, 4, accuracy: 0.3)
        XCTAssertNil(profile.captions)
        XCTAssertNil(profile.music)
        XCTAssertEqual(profile.framing.kind, .screen)
        XCTAssertEqual(profile.hook.kind, .textFirst)
        XCTAssertEqual(profile.energy, .calm)
        XCTAssertEqual(profile.purposeID, "tutorial")
        XCTAssertGreaterThan(profile.brightness, 0.9)
    }

    func testTraitsListEverythingAndColoursStartOff() {
        let profile = StyleScanner.profile(from: shortInput(), source: "TikTok")
        let traits = profile.traits
        XCTAssertEqual(traits.map(\.id), StyleTraitID.allCases)
        XCTAssertEqual(traits.first { $0.id == .colours }?.copiedByDefault, false)
        XCTAssertTrue(traits.filter { $0.id != .colours }.allSatisfy(\.copiedByDefault))
        XCTAssertTrue(traits.allSatisfy { !$0.value.isEmpty })
    }

    func testSummaryLinesCarryNoWordsFromTheVideo() {
        let profile = StyleScanner.profile(from: shortInput(), source: "TikTok")
        let lines = profile.summaryLines
        XCTAssertFalse(lines.contains("SAVED"))
        XCTAssertFalse(lines.contains("TikTok"))
        XCTAssertTrue(lines.contains("Vertical"))
    }

    func testNearestFormat() {
        XCTAssertEqual(VideoFormat.nearest(width: 1920, height: 1080), .landscape)
        XCTAssertEqual(VideoFormat.nearest(width: 1080, height: 1920), .vertical)
        XCTAssertEqual(VideoFormat.nearest(width: 1080, height: 1080), .square)
        XCTAssertEqual(VideoFormat.nearest(width: 1080, height: 1350), .portrait)
        XCTAssertEqual(VideoFormat.nearest(width: 2880, height: 1800), .landscape)
        XCTAssertEqual(VideoFormat.nearest(width: 0, height: 0), .landscape)
    }

    func testSampleTimesAreCapped() {
        XCTAssertEqual(StyleMeasure.sampleTimes(duration: 2).count, 8)
        XCTAssertEqual(StyleMeasure.sampleTimes(duration: 600).count, Int(StyleMeasure.maxSeconds * StyleMeasure.framesPerSecond))
        XCTAssertEqual(StyleMeasure.sampleTimes(duration: 0), [])
    }
}

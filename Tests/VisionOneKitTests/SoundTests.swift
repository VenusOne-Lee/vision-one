import XCTest
@testable import VisionOneKit

final class SpeechRegionTests: XCTestCase {
    func testBridgesShortGapsAndKeepsLongOnes() {
        let words = [TimeSpan(start: 1, end: 1.4), TimeSpan(start: 1.6, end: 2), TimeSpan(start: 5, end: 6)]
        let timeline = ExportTimeline(keep: nil, sourceDuration: 10, frameRate: 0)
        let regions = Speech.outputRegions(words: words, timeline: timeline, bridge: 0.8)
        XCTAssertEqual(regions, [TimeSpan(start: 1, end: 2), TimeSpan(start: 5, end: 6)])
    }

    func testMapsThroughCutsAndDropsCutWords() {
        // 2...4 is cut, so the word at 5 plays at 3 and the word at 3 is gone.
        let words = [TimeSpan(start: 0.5, end: 1), TimeSpan(start: 3, end: 3.5), TimeSpan(start: 5, end: 6)]
        let timeline = ExportTimeline(keep: [0..<2, 4..<10], sourceDuration: 10, frameRate: 0)
        let regions = Speech.outputRegions(words: words, timeline: timeline, bridge: 0)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[1].start, 3, accuracy: 1e-9)
        XCTAssertEqual(regions[1].end, 4, accuracy: 1e-9)
    }

    func testWordAcrossACutKeepsBothParts() {
        let words = [TimeSpan(start: 1, end: 5)]
        let timeline = ExportTimeline(keep: [0..<2, 4..<10], sourceDuration: 10, frameRate: 0)
        let regions = Speech.outputRegions(words: words, timeline: timeline, bridge: 0.1)
        XCTAssertEqual(regions.count, 1) // 1..<2 and 2..<3 touch
        XCTAssertEqual(regions[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(regions[0].end, 3, accuracy: 1e-9)
    }
}

final class MusicEnvelopeTests: XCTestCase {
    let bed = MusicBed(libraryID: "still-water", title: "Still water", licence: SoundLibrary.licence,
                       levelDB: -14, duckDB: 12, fadeIn: 1, fadeOut: 2)

    func testLevelDuckAndFades() {
        let envelope = MusicEnvelope(duration: 20, bed: bed, speech: [TimeSpan(start: 5, end: 8)])
        let level = MusicEnvelope.gain(db: -14)
        let ducked = MusicEnvelope.gain(db: -26)
        XCTAssertEqual(envelope.gain(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(envelope.gain(at: 3), level, accuracy: 1e-5)
        XCTAssertEqual(envelope.gain(at: 6.5), ducked, accuracy: 1e-5)
        // Already dipping before the first word, back up after the release.
        XCTAssertLessThan(envelope.gain(at: 4.9), level)
        XCTAssertEqual(envelope.gain(at: 9), level, accuracy: 1e-5)
        XCTAssertEqual(envelope.gain(at: 20), 0, accuracy: 1e-6)
        XCTAssertLessThan(envelope.gain(at: 19), level)
    }

    func testCloseRegionsStayDucked() {
        // 0.5 s apart is less than lead + release, so no pump between them.
        let envelope = MusicEnvelope(duration: 20, bed: bed,
                                     speech: [TimeSpan(start: 5, end: 6), TimeSpan(start: 6.5, end: 8)])
        XCTAssertEqual(envelope.gain(at: 6.25), MusicEnvelope.gain(db: -26), accuracy: 1e-5)
    }

    func testPointsAreInOrderAndInside() {
        let envelope = MusicEnvelope(duration: 10, bed: bed,
                                     speech: [TimeSpan(start: 0, end: 2), TimeSpan(start: 9.5, end: 12)])
        let times = envelope.points.map(\.time)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last, 10)
        XCTAssertTrue(envelope.points.allSatisfy { $0.gain >= 0 && $0.gain <= 1 })
    }

    func testShortVideoSharesTheFades() {
        let envelope = MusicEnvelope(duration: 1.5, bed: bed, speech: [])
        XCTAssertEqual(envelope.gain(at: 0.5), MusicEnvelope.gain(db: -14), accuracy: 1e-5)
        XCTAssertEqual(envelope.gain(at: 1.5), 0, accuracy: 1e-6)
    }

    func testNoDuckWhenDepthIsZero() {
        var flat = bed
        flat.duckDB = 0
        let envelope = MusicEnvelope(duration: 20, bed: flat, speech: [TimeSpan(start: 5, end: 8)])
        XCTAssertEqual(envelope.gain(at: 6.5), MusicEnvelope.gain(db: -14), accuracy: 1e-5)
    }
}

final class SoundMixPlanTests: XCTestCase {
    func testLoopsMusicToCoverTheVideo() {
        let plan = SoundPlan(music: .library(SoundLibrary.music[0]))
        let timeline = ExportTimeline(keep: nil, sourceDuration: 25, frameRate: 0)
        let mix = SoundMixPlan(plan: plan, timeline: timeline, words: [], musicDuration: 10)
        XCTAssertEqual(mix.music.map(\.outputStart), [0, 10, 20])
        XCTAssertEqual(mix.music.last?.duration ?? 0, 5, accuracy: 1e-9)
        XCTAssertNotNil(mix.musicEnvelope)
    }

    func testPlaysOnceWithoutLooping() {
        var bed = MusicBed.library(SoundLibrary.music[0])
        bed.loops = false
        let timeline = ExportTimeline(keep: nil, sourceDuration: 25, frameRate: 0)
        let mix = SoundMixPlan(plan: SoundPlan(music: bed), timeline: timeline, words: [], musicDuration: 10)
        XCTAssertEqual(mix.music.count, 1)
        XCTAssertEqual(mix.music[0].duration, 10, accuracy: 1e-9)
    }

    func testNoMusicWhenFileUnreadable() {
        let timeline = ExportTimeline(keep: nil, sourceDuration: 25, frameRate: 0)
        let mix = SoundMixPlan(plan: SoundPlan(music: .library(SoundLibrary.music[0])),
                               timeline: timeline, words: [], musicDuration: nil)
        XCTAssertTrue(mix.music.isEmpty)
        XCTAssertNil(mix.musicEnvelope)
    }

    func testEffectsFollowCutsAndDropWhenCut() {
        let moved = PlacedEffect(soundID: "pop", at: 6)
        let cut = PlacedEffect(soundID: "pop", at: 3)
        let suggested = PlacedEffect(soundID: "pop", at: 8, state: .proposed, isManual: false)
        let plan = SoundPlan(effects: [moved, cut, suggested])
        let timeline = ExportTimeline(keep: [0..<2, 4..<10], sourceDuration: 10, frameRate: 0)
        let mix = SoundMixPlan(plan: plan, timeline: timeline, words: [], musicDuration: nil)
        XCTAssertEqual(mix.effects.count, 1)
        XCTAssertEqual(mix.effects[0].id, moved.id)
        XCTAssertEqual(mix.effects[0].outputStart, 4, accuracy: 1e-9)
    }

    func testOverlappingEffectsGetTheirOwnLanes() {
        let plan = SoundPlan(effects: [
            PlacedEffect(soundID: "ding", at: 1),   // 1.2 s long
            PlacedEffect(soundID: "pop", at: 1.5),  // overlaps the ding
            PlacedEffect(soundID: "pop", at: 3),    // ding is over
        ])
        let timeline = ExportTimeline(keep: nil, sourceDuration: 10, frameRate: 0)
        let mix = SoundMixPlan(plan: plan, timeline: timeline, words: [], musicDuration: nil)
        XCTAssertEqual(mix.effects.map(\.lane), [0, 1, 0])
        XCTAssertEqual(mix.laneCount, 2)
    }

    func testEffectsOnSpeechAreQuieter() {
        let plan = SoundPlan(effects: [PlacedEffect(soundID: "pop", at: 1), PlacedEffect(soundID: "pop", at: 5)])
        let timeline = ExportTimeline(keep: nil, sourceDuration: 10, frameRate: 0)
        let mix = SoundMixPlan(plan: plan, timeline: timeline, words: [TimeSpan(start: 0.8, end: 1.5)], musicDuration: nil)
        XCTAssertEqual(mix.effects[0].gain, MusicEnvelope.gain(db: -16), accuracy: 1e-5)
        XCTAssertEqual(mix.effects[1].gain, MusicEnvelope.gain(db: -10), accuracy: 1e-5)
    }

    func testEffectClippedAtTheEnd() {
        let plan = SoundPlan(effects: [PlacedEffect(soundID: "ding", at: 9.5)])
        let timeline = ExportTimeline(keep: nil, sourceDuration: 10, frameRate: 0)
        let mix = SoundMixPlan(plan: plan, timeline: timeline, words: [], musicDuration: nil)
        XCTAssertEqual(mix.effects[0].duration, 0.5, accuracy: 1e-9)
    }
}

final class EffectSuggesterTests: XCTestCase {
    /// Words every half second, with a 2 s pause before 10, 20, 40 and 70.
    func words() -> [TimeSpan] {
        var spans: [TimeSpan] = []
        var t = 1.0
        for pauseAt in [10.0, 20, 40, 70, 90] {
            while t + 0.4 < pauseAt - 2 {
                spans.append(TimeSpan(start: t, end: t + 0.4))
                t += 0.5
            }
            t = pauseAt
        }
        return spans
    }

    func testCalmSuggestsNothing() {
        let edits = EditList(sourceDuration: 90)
        XCTAssertTrue(EffectSuggester.suggestions(energy: .calm, words: words(), edits: edits).isEmpty)
    }

    func testLivelySpacesWhooshesOnTopics() {
        let edits = EditList(sourceDuration: 90)
        let suggestions = EffectSuggester.suggestions(energy: .lively, words: words(), edits: edits)
        XCTAssertTrue(suggestions.allSatisfy { $0.soundID == "whoosh" && $0.state == .proposed && !$0.isManual })
        // 10 is under 25 s after the first word at 1, so 40 and 70 win.
        XCTAssertEqual(suggestions.map(\.at), [40 - 0.25, 70 - 0.25])
    }

    func testViralAddsAPopAndAllowsMore() {
        let edits = EditList(sourceDuration: 90)
        let suggestions = EffectSuggester.suggestions(energy: .viral, words: words(), edits: edits)
        XCTAssertEqual(suggestions.first?.soundID, "pop")
        XCTAssertEqual(suggestions.first?.at, 1)
        let expectedTimes: [Double] = [9.75, 19.75, 39.75, 69.75]
        XCTAssertEqual(suggestions.dropFirst().map(\.at), expectedTimes)
    }

    func testCutWordsAreSkipped() {
        var edits = EditList(sourceDuration: 90)
        edits.add(Cut(span: TimeSpan(start: 39, end: 45)))
        let suggestions = EffectSuggester.suggestions(energy: .lively, words: words(), edits: edits)
        XCTAssertFalse(suggestions.contains { abs($0.at - 39.75) < 0.01 })
    }

    func testTurningTheDialKeepsTheUsersEffects() {
        let edits = EditList(sourceDuration: 90)
        var plan = SoundPlan()
        plan.setEnergy(.viral, words: words(), edits: edits)
        let accepted = plan.effects[1].id
        plan.setState(.accepted, for: accepted)
        plan.effects.append(PlacedEffect(soundID: "ding", at: 50))

        plan.setEnergy(.calm, words: words(), edits: edits)
        XCTAssertEqual(plan.energy, .calm)
        XCTAssertEqual(Set(plan.effects.map(\.soundID)), ["whoosh", "ding"])
        XCTAssertTrue(plan.effects.contains { $0.id == accepted })

        // Back to Viral: no new suggestion right on top of the accepted one.
        plan.setEnergy(.viral, words: words(), edits: edits)
        let near = plan.effects.filter { abs($0.at - 9.75) < 1.5 }
        XCTAssertEqual(near.count, 1)
    }
}

final class SoundPlanFileTests: XCTestCase {
    func testRoundTripsAndMovesEffects() throws {
        var plan = SoundPlan(music: .library(SoundLibrary.music[1]), energy: .lively)
        plan.effects.append(PlacedEffect(soundID: "whoosh", at: 3, state: .proposed, isManual: false))
        plan.move(id: plan.effects[0].id, to: 12, sourceDuration: 10)
        XCTAssertEqual(plan.effects[0].at, 10)
        XCTAssertEqual(plan.effects[0].state, .accepted)
        XCTAssertTrue(plan.effects[0].isManual)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sound-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try plan.write(to: url)
        XCTAssertEqual(try SoundPlan.read(from: url), plan)
    }

    func testMissingFileIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID()).json")
        let plan = try SoundPlan.load(from: url)
        XCTAssertNil(plan.music)
        XCTAssertTrue(plan.isEmpty)
    }

    func testTakeKeepsSoundNextToEdits() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One 2026-10-27 at 10.53.12"))
        XCTAssertEqual(take.soundURL.lastPathComponent, "sound.json")
    }
}

final class SoundSynthTests: XCTestCase {
    func testEveryEffectRendersAtItsLength() throws {
        for sound in SoundLibrary.effects {
            let samples = try XCTUnwrap(SoundSynth.render(sound.id), sound.id)
            XCTAssertEqual(Double(samples.count) / SoundSynth.sampleRate, sound.duration, accuracy: 0.001, sound.id)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertEqual(peak, 0.89, accuracy: 0.001, sound.id)
            XCTAssertFalse(samples.contains { $0.isNaN }, sound.id)
        }
    }

    func testRendersAreTheSameEveryTime() {
        XCTAssertEqual(SoundSynth.render("whoosh"), SoundSynth.render("whoosh"))
    }

    func testUnknownSoundIsNil() {
        XCTAssertNil(SoundSynth.render("airhorn"))
    }

    func testMusicLoopsAtItsLength() throws {
        let bed = SoundLibrary.music[2] // the shortest loop
        let samples = try XCTUnwrap(SoundSynth.render(bed.id))
        XCTAssertEqual(Double(samples.count) / SoundSynth.sampleRate, bed.duration, accuracy: 0.001)
        // The wrap-around tail means the loop doesn't start from silence.
        XCTAssertGreaterThan(abs(samples[100]), 0)
    }

    func testWAVHeader() {
        let data = WAVFile.data(samples: [0, 1, -1], sampleRate: 48_000, channels: 2)
        XCTAssertEqual(data.count, 44 + 3 * 4)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        // Second frame, left channel: full scale.
        XCTAssertEqual(Int16(littleEndian: data[48..<50].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }), 32767)
    }
}

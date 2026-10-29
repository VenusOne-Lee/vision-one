import XCTest
@testable import VisionOneKit

final class AgentTests: XCTestCase {
    /// "One. Two two. Three three three. Four." at one word a second.
    func transcript(_ sentences: [String], wordSeconds: Double = 1) -> Transcript {
        var words: [TranscriptWord] = []
        var t = 0.0
        for sentence in sentences {
            for w in sentence.split(separator: " ") {
                words.append(TranscriptWord(id: words.count, text: String(w), start: t, end: t + wordSeconds * 0.9))
                t += wordSeconds
            }
        }
        return Transcript(language: "en", engine: "test", duration: t, segments: [TranscriptSegment(words: words)])
    }

    func ladder(_ reply: @escaping (AIRequest) -> String) -> AILadder {
        AILadder(providers: [FakeProvider(.chatGPT, rung: .chatGPT, reply: reply)],
                 gate: OutboundGate(approver: FixedApprover(.allowOnce)))
    }

    // MARK: Sentences

    func testSentencesSkipCutWords() {
        let t = transcript(["Hello there.", "Um so.", "This is it."])
        var edits = EditList(sourceDuration: t.duration)
        edits.add(Cut(span: TimeSpan(start: 2, end: 4)))
        let sentences = t.sentences(keeping: edits)
        XCTAssertEqual(sentences.map(\.text), ["Hello there.", "This is it."])
        XCTAssertEqual(sentences.map(\.index), [0, 1])
    }

    func testSentencesSplitOnLongPauses() {
        let words = [TranscriptWord(id: 0, text: "no", start: 0, end: 0.5),
                     TranscriptWord(id: 1, text: "punctuation", start: 3, end: 3.5)]
        let t = Transcript(language: "en", engine: "t", duration: 4, segments: [TranscriptSegment(words: words)])
        XCTAssertEqual(t.sentences().count, 2)
    }

    // MARK: Editor

    func testGoalParsing() {
        XCTAssertEqual(EditorAgent.Goal.parse("make it 60s").targetSeconds, 60)
        XCTAssertEqual(EditorAgent.Goal.parse("Under 2 minutes please").targetSeconds, 120)
        XCTAssertEqual(EditorAgent.Goal.parse("90 seconds").targetSeconds, 90)
        XCTAssertEqual(EditorAgent.Goal.parse("cut to 1:30").targetSeconds, 90)
        XCTAssertEqual(EditorAgent.Goal.parse("about a minute").targetSeconds, 60)
        XCTAssertNil(EditorAgent.Goal.parse("cut the part about pricing").targetSeconds)
        XCTAssertEqual(EditorAgent.Goal.parse("cut the part about pricing").ask, "cut the part about pricing")
    }

    func testPickHitsTargetDroppingWeakestFirst() {
        let t = transcript(["a b c d.", "e f.", "g h i.", "j."])
        let s = t.sentences()
        let keep = [0: 0.9, 1: 0.1, 2: 0.2, 3: 0.95]
        let picked = EditorAgent.pick(s, keep: keep, currentSeconds: 10, goal: .init(targetSeconds: 6), threshold: 0.3)
        XCTAssertEqual(picked.map(\.index), [1, 2])
    }

    func testPickWithoutTargetUsesThreshold() {
        let s = transcript(["a.", "b.", "c."]).sentences()
        let picked = EditorAgent.pick(s, keep: [0: 0.5, 1: 0.1, 2: 0.29], currentSeconds: 3, goal: .init(),
                                      threshold: 0.3)
        XCTAssertEqual(picked.map(\.index), [1, 2])
    }

    func testPickNeverCutsEverythingAndKeepsRefused() {
        let s = transcript(["a.", "b.", "c."]).sentences()
        let picked = EditorAgent.pick(s, keep: [0: 0.1, 1: 0.1], currentSeconds: 100, goal: .init(targetSeconds: 1),
                                      threshold: 0.3)
        XCTAssertEqual(picked.map(\.index), [0, 1]) // sentence 2 had no score, so it stays
    }

    func testAdjacentCutsMerge() {
        let s = transcript(["a.", "b.", "c.", "d."]).sentences()
        let cuts = EditorAgent.cuts(for: [s[1], s[2]], all: s)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start, 1)
        XCTAssertEqual(cuts[0].state, .proposed)
        XCTAssertEqual(cuts[0].reason, "trim")
        XCTAssertLessThanOrEqual(cuts[0].end, 3)
    }

    func testEditorProposesThroughLadder() async throws {
        let t = transcript(["Welcome to the demo.", "Sorry my cat is here.", "Click export and you're done."])
        let editor = EditorAgent(ladder: ladder { _ in
            #"[{"name":"s0","probability":0.9},{"name":"s1","probability":0.05},{"name":"s2","probability":0.95}]"#
        })
        let cuts = try await editor.propose(transcript: t, edits: EditList(sourceDuration: t.duration),
                                            brief: Purpose.demo.brief(), goal: .init(), energy: .lively)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].start, 4)
    }

    // MARK: Producer

    func testProducerChecks() {
        let ok = ProducerAgent.check(.init(micName: "MacBook Mic", micPeakDB: -18, notificationsSilenced: true))
        XCTAssertTrue(ok.isEmpty)
        let notes = ProducerAgent.check(.init(micName: nil, freeDiskGB: 1, onBattery: true, batteryPercent: 10,
                                              notificationsSilenced: false, purposeID: "talkingHead"))
        XCTAssertEqual(notes.first?.level, .fix)
        XCTAssertEqual(Set(notes.map(\.id)), ["mic.none", "disk.low", "battery.low", "focus.off", "camera.off"])
    }

    func testProducerOutline() async throws {
        let producer = ProducerAgent(ladder: ladder { _ in
            #"{"hook":"Ever lost a receipt?","points":["Snap it","Sort it"],"payoff":"Done in a tap","cta":"Try it"}"#
        })
        let outline = try await producer.outline(about: "receipt app", brief: Purpose.launch.brief())
        XCTAssertEqual(outline.points.count, 2)
    }

    // MARK: Clipper

    func testClipCandidatesAreSentenceBounded() {
        let s = transcript(Array(repeating: "one two three four five.", count: 10)).sentences()
        let c = ClipperAgent.candidates(from: s, minSeconds: 15, maxSeconds: 60)
        XCTAssertFalse(c.isEmpty)
        XCTAssertTrue(c.allSatisfy { $0.span.duration >= 14 && $0.span.duration <= 60 })
    }

    func testClipperPicksBestWithoutOverlap() async throws {
        let s = transcript(Array(repeating: "one two three four five.", count: 12)).sentences()
        let candidates = ClipperAgent.candidates(from: s, minSeconds: 15, maxSeconds: 60)
        let clipper = ClipperAgent(ladder: ladder { req in
            if req.task == .clipTitle { return #"{"clips":[{"n":1,"title":"First","hook":"Look"}]}"# }
            let names = req.input.split(separator: "\n").compactMap { $0.split(separator: " ").first }
                .filter { $0.hasPrefix("c") }
            return "[" + names.map { n in #"{"name":"\#(n)","score":\#(n == "c0" ? 3 : 1)}"# }.joined(separator: ",") + "]"
        })
        let picks = try await clipper.pick(from: candidates, brief: Purpose.short.brief(), count: 2)
        XCTAssertEqual(picks.count, 2)
        XCTAssertEqual(picks[0].title, "First")
        XCTAssertEqual(picks[0].score, 1)
        XCTAssertFalse(picks[0].span.overlaps(picks[1].span))
    }

    func testClipPickBecomesProposedAgentClip() {
        let clip = ClipPick(start: 2, end: 20, score: 0.8, title: "T", hook: "H", format: "square").clip
        XCTAssertEqual(clip.origin, Clip.Origin.agent)
        XCTAssertEqual(clip.state, .proposed)
        XCTAssertEqual(clip.format, .square)
        var list = ClipList()
        XCTAssertEqual(list.propose([clip], sourceDuration: 30).count, 1)
        XCTAssertTrue(list.propose([clip], sourceDuration: 30).isEmpty)
    }

    // MARK: Sharer

    func testSharerMapsChaptersToEditedTime() async throws {
        let t = transcript(Array(repeating: "one two three four five six seven eight nine ten.", count: 6))
        var edits = EditList(sourceDuration: t.duration)
        edits.add(Cut(span: TimeSpan(start: 10, end: 20)))  // sentence 2 is cut
        let sharer = SharerAgent(ladder: ladder { _ in
            #"""
            {"title":"T","description":"D","chapters":[{"sentence":1,"title":"Intro"},{"sentence":2,"title":"Middle"},{"sentence":4,"title":"End"}],
             "posts":[{"network":"X","text":"post"}],"launch":{"name":"Thing","oneLine":"Does a thing"}}
            """#
        })
        let pack = try await sharer.draft(transcript: t, edits: edits, brief: Purpose.launch.brief(), launch: true)
        XCTAssertEqual(pack.title, "T")
        XCTAssertEqual(pack.chapters.map(\.start), [0, 10, 30])
        XCTAssertEqual(pack.chapterText.split(separator: "\n").first, "0:00 Intro")
        XCTAssertEqual(pack.posts.first?.network, "x")
        XCTAssertEqual(pack.launch?.name, "Thing")
    }

    func testSharerWontWriteFromSmallTalk() async throws {
        let t = transcript(["Hi there.", "Is this on?", "Okay, cool, thanks."])
        let sharer = SharerAgent(ladder: ladder { _ in
            #"{"title":"Intro","description":"This is a demo of the product."}"#
        })
        do {
            _ = try await sharer.draft(transcript: t, edits: EditList(sourceDuration: t.duration),
                                       brief: Purpose.demo.brief())
            XCTFail("drafted posts from small talk")
        } catch let error as SharerAgent.TooLittleSaid {
            XCTAssertLessThan(error.words, SharerAgent.minimumWords)
            XCTAssertTrue(AgentRunner.message(for: error).hasPrefix("Too little was said"))
        }
    }

    // MARK: Purposes and energy

    func testPurposeIDsMatchTemplateLooks() {
        XCTAssertEqual(Purpose.all.map(\.id), ["launch", "demo", "short", "tutorial", "bugReport", "update", "talkingHead"])
        XCTAssertEqual(Purpose.short.energy, .viral)
        XCTAssertEqual(Purpose.bugReport.energy, .calm)
    }

    func testEnergyTunesCleanup() {
        XCTAssertLessThan(CleanupSettings(energy: .viral).minPause, CleanupSettings(energy: .calm).minPause)
        XCTAssertFalse(Energy.calm.profile.punchIns)
        XCTAssertTrue(Energy.viral.profile.punchIns)
    }

    func testBriefInstructionsIncludeHouseStyleAndParts() {
        let brief = Purpose.launch.brief(houseStyle: "Short sentences.")
        let text = brief.instructions("Lead.", parts: ["title"])
        XCTAssertTrue(text.contains("House style: Short sentences."))
        XCTAssertTrue(text.contains("Title: A plain title"))
        XCTAssertFalse(text.contains("Hook:"))
    }

    func testNextPlanFollowsHome() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vision-one-next-plan-\(UUID().uuidString)"))
        XCTAssertNil(TakePlan.next(in: defaults))
        defaults.set("tutorial", forKey: TakePlan.nextPurposeKey)
        XCTAssertEqual(TakePlan.next(in: defaults)?.energy, Purpose.tutorial.energy)
        defaults.set("viral", forKey: TakePlan.nextEnergyKey)
        XCTAssertEqual(TakePlan.next(in: defaults)?.purposeID, "tutorial")
        XCTAssertEqual(TakePlan.next(in: defaults)?.energy, .viral)
    }

    func testTakePlanRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let take = Take(folder: folder)
        try TakePlan(purpose: .short).write(for: take)
        XCTAssertEqual(TakePlan.load(for: take)?.energy, .viral)
        XCTAssertEqual(TakePlan.load(for: take)?.targetSeconds, 59)
    }
}

final class PurposePromptTests: XCTestCase {
    func testBriefFillsVariablesAndLayersPreset() {
        let preset = PromptPreset(name: "Mine", prompts: [.title: "Title for {product}, five words.", .houseStyle: "Dry and short."])
        let brief = Purpose.launch.brief(preset: preset, variables: PromptVariables(product: "Vision One"))
        XCTAssertEqual(brief.parts["title"], "Title for Vision One, five words.")
        XCTAssertEqual(brief.houseStyle, "Dry and short.")
        XCTAssertTrue(brief.parts["hook"]!.contains("Vision One"))
        XCTAssertFalse(brief.parts.values.contains { $0.contains("{") })
    }

    func testBriefWithoutListingUsesPlainWords() {
        let brief = Purpose.launch.brief(preset: nil)
        XCTAssertTrue(brief.parts["outro"]!.hasPrefix("End on where to try it: the link."))
        XCTAssertNil(brief.houseStyle)
    }
}

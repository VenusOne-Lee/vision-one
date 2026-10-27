import XCTest
@testable import VisionOneKit

final class ShareTargetTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/take")

    private func url(_ preset: ExportPreset) -> URL {
        folder.appendingPathComponent("take\(preset.fileSuffix).mp4")
    }

    private var pack: SharePack {
        SharePack(title: "Vision One in two minutes", description: "A free Mac recorder.",
                  chapters: [.init(start: 0, title: "Intro"), .init(start: 30, title: "Record"),
                             .init(start: 75, title: "Share")],
                  posts: [.init(network: "x", text: "Built it in two weekends"),
                          .init(network: "linkedin", text: "Vision One is out & free")],
                  launch: nil, provider: nil, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testPicksTheFileThatSuitsEachTarget() {
        let all = Dictionary(uniqueKeysWithValues: ExportPreset.allCases.map { ($0, url($0)) })
        XCTAssertEqual(ShareTarget.whatsapp.file(from: all)?.preset, .whatsapp)
        XCTAssertEqual(ShareTarget.linkedin.file(from: all)?.preset, .square)
        XCTAssertEqual(ShareTarget.x.file(from: all)?.preset, .hd1080)
        XCTAssertEqual(ShareTarget.youtube.file(from: all)?.preset, .hd1080)
    }

    func testFallsBackToWhateverWasExported() {
        let onlyVertical = [ExportPreset.vertical: url(.vertical)]
        for target in ShareTarget.allCases {
            XCTAssertEqual(target.file(from: onlyVertical)?.preset, .vertical, target.title)
        }
        XCTAssertNil(ShareTarget.x.file(from: [:]))
    }

    func testEveryPresetIsSomewhereInEveryList() {
        for target in ShareTarget.allCases {
            XCTAssertEqual(Set(target.preferred), Set(ExportPreset.allCases), target.title)
        }
    }

    func testUsesTheSharersPostForTheNetwork() {
        XCTAssertEqual(ShareTarget.x.text(in: pack), "Built it in two weekends")
        XCTAssertEqual(ShareTarget.linkedin.text(in: pack), "Vision One is out & free")
        XCTAssertNil(ShareTarget.whatsapp.text(in: pack))
        XCTAssertNil(ShareTarget.x.text(in: nil))
    }

    func testYouTubeGetsTitleDescriptionAndChapters() {
        XCTAssertEqual(ShareTarget.youtube.text(in: pack),
                       "Vision One in two minutes\n\nA free Mac recorder.\n\n0:00 Intro\n0:30 Record\n1:15 Share")
    }

    func testComposerLinksCarryTheTextSafely() {
        let link = ShareTarget.linkedin.composer(text: "Vision One is out & free").absoluteString
        XCTAssertTrue(link.hasPrefix("https://www.linkedin.com/feed/?shareActive=true&text="))
        XCTAssertTrue(link.contains("%26"), link)
        XCTAssertFalse(link.contains(" "))
        XCTAssertEqual(ShareTarget.x.composer(text: nil).absoluteString, "https://x.com/compose/post")
        XCTAssertEqual(ShareTarget.whatsapp.composer(text: "hi").absoluteString, "https://wa.me/?text=hi")
        XCTAssertEqual(ShareTarget.youtube.composer(text: "ignored").host, "www.youtube.com")
    }

    func testNetworkNames() {
        XCTAssertEqual(ShareTarget(network: "Twitter"), .x)
        XCTAssertEqual(ShareTarget(network: "linkedin"), .linkedin)
        XCTAssertNil(ShareTarget(network: "tiktok"))
    }

    func testStepsSayNothingPostsByItself() {
        let steps = ShareTarget.linkedin.steps(file: .square)
        XCTAssertTrue(steps.first?.contains("Square") == true)
        XCTAssertTrue(steps.last?.contains("Nothing posts") == true)
    }

    func testInPlaceApprovalIsRecordedForPostsOnly() async {
        let gate = OutboundGate(approver: FixedApprover(.deny))
        await gate.approvedInPlace(SharerAgent.postRequest("hi", to: "x.com", network: "x"))
        await gate.approvedInPlace(OutboundRequest(provider: .chatGPT, providerName: "ChatGPT",
                                                   destination: "chatgpt.com", task: AITask("t"),
                                                   summary: "s", payload: "p"))
        let history = await gate.history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.request.destination, "x.com")
        XCTAssertEqual(history.first?.decision, .allowOnce)
    }
}

final class ExportProgressTests: XCTestCase {
    func testWeighsPresetsByHowLongTheyTake() {
        var batch = ExportBatch([.hd1080, .hd720])
        batch.start(.hd1080)
        batch.apply(.exporting(preset: .hd1080, progress: 0.5))
        // 1080p counts three times as much as 720p here.
        let weighted = ExportProgress.overall(batch) { $0 == .hd1080 ? 3 : 1 }
        XCTAssertEqual(weighted, 1.5 / 4, accuracy: 1e-9)
        XCTAssertEqual(ExportProgress.overall(batch) { _ in 0 }, batch.progress, accuracy: 1e-9)
    }

    func testRemainingWaitsForEnoughToGoOn() {
        XCTAssertNil(ExportProgress.remaining(progress: 0.01, elapsed: 10))
        XCTAssertNil(ExportProgress.remaining(progress: 0.5, elapsed: 1))
        XCTAssertNil(ExportProgress.remaining(progress: 1, elapsed: 10))
        XCTAssertEqual(ExportProgress.remaining(progress: 0.25, elapsed: 10) ?? 0, 30, accuracy: 1e-9)
    }

    func testRemainingText() {
        XCTAssertEqual(ExportProgress.remainingText(4), "a few seconds left")
        XCTAssertEqual(ExportProgress.remainingText(38), "about 40 s left")
        XCTAssertEqual(ExportProgress.remainingText(70), "about a minute left")
        XCTAssertEqual(ExportProgress.remainingText(200), "about 3 min left")
    }

    func testFilesByPreset() {
        var batch = ExportBatch([.hd1080, .square])
        let url = URL(fileURLWithPath: "/tmp/a.mp4")
        batch.start(.hd1080)
        batch.apply(.exporting(preset: .hd1080, progress: 0.2))
        batch.apply(.done(preset: .hd1080, url: url, bytes: 1))
        XCTAssertEqual(batch.files, [.hd1080: url])
    }
}

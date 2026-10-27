import XCTest
@testable import VisionOneKit

final class FrameRectTests: XCTestCase {
    func testCenteredSlidesBackInsideTheFrame() {
        let rect = FrameRect.centered(x: 0.95, y: 0.05, width: 0.5, height: 0.5)
        XCTAssertEqual(rect.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(rect.y, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.5, accuracy: 1e-9)
    }

    func testMappingPutsAnInnerBoxInFrameSpace() {
        let zoom = FrameRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let crop = FrameRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let mapped = zoom.mapping(crop)
        XCTAssertEqual(mapped, FrameRect(x: 0.625, y: 0.5, width: 0.25, height: 0.5))
    }

    func testIoU() {
        let a = FrameRect(x: 0, y: 0, width: 0.2, height: 0.2)
        XCTAssertEqual(a.iou(a), 1, accuracy: 1e-9)
        XCTAssertEqual(a.iou(FrameRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)), 0)
    }
}

final class ZoomPlannerTests: XCTestCase {
    private func log(_ clicks: [(Double, Double, Double)]) -> EventLog {
        var log = EventLog(displayWidth: 1000, displayHeight: 500)
        for (t, x, y) in clicks {
            log.append(InputEvent(kind: .move, t: max(0, t - 0.1), x: x, y: y))
            log.append(InputEvent(kind: .leftDown, t: t, x: x, y: y))
            log.append(InputEvent(kind: .leftUp, t: t + 0.05, x: x, y: y))
        }
        return log
    }

    func testOneClickBecomesOneProposedZoomThatLandsBeforeTheClick() {
        let style = ZoomStyle.energy(.lively)
        let zooms = ZoomPlanner.propose(from: log([(5, 250, 125)]), style: style, sourceDuration: 30)
        XCTAssertEqual(zooms.count, 1)
        let zoom = zooms[0]
        XCTAssertEqual(zoom.state, .proposed)
        XCTAssertEqual(zoom.reason, Zoom.Reason.click)
        XCTAssertEqual(zoom.start, 5 - style.lead, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(zoom.start + zoom.easeTime, 5)
        XCTAssertEqual(zoom.centerX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(zoom.centerY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(zoom.scale, 2)
    }

    func testClicksCloseInTimeAndPlaceShareOneZoom() {
        let zooms = ZoomPlanner.propose(from: log([(5, 500, 250), (6, 520, 260), (7.5, 510, 240)]),
                                        style: .energy(.lively), sourceDuration: 30)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].end, 7.5 + ZoomStyle.energy(.lively).hold, accuracy: 1e-9)
    }

    func testFarApartClicksGetTheirOwnZooms() {
        let zooms = ZoomPlanner.propose(from: log([(5, 100, 100), (20, 900, 400)]),
                                        style: .energy(.lively), sourceDuration: 30)
        XCTAssertEqual(zooms.count, 2)
    }

    func testQuickClicksFarApartHandOverInsteadOfOverlapping() {
        let zooms = ZoomPlanner.propose(from: log([(5, 50, 50), (7, 950, 450)]),
                                        style: .energy(.lively), sourceDuration: 30)
        XCTAssertEqual(zooms.count, 2)
        XCTAssertLessThanOrEqual(zooms[0].end, zooms[1].start + 1e-9)
    }

    func testClicksInsideCutsDontZoom() {
        let zooms = ZoomPlanner.propose(from: log([(5, 500, 250)]), style: .energy(.calm), sourceDuration: 30,
                                        removed: [TimeSpan(start: 3, end: 10)])
        XCTAssertTrue(zooms.isEmpty)
    }

    func testEnergyChangesScale() {
        XCTAssertLessThan(ZoomStyle.energy(.calm).scale, ZoomStyle.energy(.lively).scale)
        XCTAssertLessThan(ZoomStyle.energy(.lively).scale, ZoomStyle.energy(.viral).scale)
    }
}

final class ZoomTrackTests: XCTestCase {
    private func zoom(_ start: Double, _ end: Double, x: Double = 0.25, y: Double = 0.25, scale: Double = 2,
                      state: ProposalState = .accepted) -> Zoom {
        Zoom(span: TimeSpan(start: start, end: end), scale: scale, centerX: x, centerY: y, ramp: 0.5, state: state)
    }

    func testFullFrameOutsideZooms() {
        let track = ZoomTrack(zooms: [zoom(2, 6)])
        XCTAssertEqual(track.viewport(atSource: 1), .full)
        XCTAssertEqual(track.viewport(atSource: 7), .full)
    }

    func testEasesInHoldsAndEasesOut() {
        let track = ZoomTrack(zooms: [zoom(2, 6)])
        let held = track.viewport(atSource: 4)
        XCTAssertEqual(held.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(held.x, 0, accuracy: 1e-9)
        let easing = track.viewport(atSource: 2.25)
        XCTAssertGreaterThan(easing.width, 0.5)
        XCTAssertLessThan(easing.width, 1)
        let leaving = track.viewport(atSource: 5.9)
        XCTAssertGreaterThan(leaving.width, 0.5)
    }

    func testProposedZoomsDontMoveTheCamera() {
        let track = ZoomTrack(zooms: [zoom(2, 6, state: .proposed)])
        XCTAssertEqual(track.viewport(atSource: 4), .full)
    }

    func testChainedZoomsPanWithoutZoomingOut() {
        let track = ZoomTrack(zooms: [zoom(2, 6, x: 0.25), zoom(6, 10, x: 0.75)])
        // At the hand-over the camera is still zoomed in.
        let handover = track.viewport(atSource: 6.1)
        XCTAssertEqual(handover.width, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(handover.midX, 0.25)
        XCTAssertLessThan(handover.midX, 0.75)
        XCTAssertEqual(track.viewport(atSource: 5.95).width, 0.5, accuracy: 1e-9)
    }

    func testFollowsTheSmoothedCursor() {
        var z = zoom(0, 10)
        z.followsCursor = true
        let cursor = (0..<100).map { CursorPoint(t: Double($0) * 0.1, x: 0.8, y: 0.8) }
        let track = ZoomTrack(zooms: [z], cursor: cursor)
        let rect = track.viewport(atSource: 5)
        XCTAssertEqual(rect.midX, 0.75, accuracy: 1e-9) // 0.8, slid back inside
    }

    func testViewportStaysInsideTheFrame() {
        let track = ZoomTrack(zooms: [zoom(0, 4, x: 1, y: 1, scale: 3)])
        for step in 0...40 {
            let r = track.viewport(atSource: Double(step) * 0.1)
            XCTAssertGreaterThanOrEqual(r.minX, -1e-9)
            XCTAssertLessThanOrEqual(r.maxX, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(r.minY, -1e-9)
            XCTAssertLessThanOrEqual(r.maxY, 1 + 1e-9)
        }
    }

    func testDraggingTheBoxSetsCentreAndScale() {
        var z = zoom(0, 4)
        z.setViewport(FrameRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
        XCTAssertEqual(z.scale, 4, accuracy: 1e-9)
        XCTAssertEqual(z.centerX, 0.625, accuracy: 1e-9)
    }
}

final class ZoomListTests: XCTestCase {
    func testProposeSkipsWhatTheUserAlreadyAnswered() {
        var list = ZoomList()
        let first = Zoom(span: TimeSpan(start: 1, end: 4), scale: 2, centerX: 0.5, centerY: 0.5, state: .proposed)
        list.propose([first])
        list.setState(.rejected, for: first.id)
        let again = Zoom(span: TimeSpan(start: 1.5, end: 4), scale: 2, centerX: 0.5, centerY: 0.5)
        XCTAssertTrue(list.propose([again]).isEmpty)
        XCTAssertEqual(list.zooms.count, 1)
    }

    func testRoundTrip() throws {
        var list = ZoomList(energy: .viral)
        list.propose([Zoom(span: TimeSpan(start: 1, end: 4), scale: 2.5, centerX: 0.3, centerY: 0.6,
                           followsCursor: true, ramp: 0.4, reason: Zoom.Reason.click)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zooms-\(UUID()).json")
        try list.write(to: url)
        XCTAssertEqual(try ZoomList.read(from: url), list)
        XCTAssertEqual(try ZoomList.load(from: url.appendingPathExtension("missing")), ZoomList())
    }
}

final class SecretScannerTests: XCTestCase {
    private func kinds(_ text: String) -> [String] {
        SecretScanner.find(in: text).map(\.kind)
    }

    private func hidden(_ text: String) -> [String] {
        SecretScanner.find(in: text).map { String(text[$0.range]) }
    }

    func testKnownKeyShapes() {
        XCTAssertEqual(kinds("OPENAI_API_KEY=sk-proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXyZ0"), ["OpenAI key"])
        XCTAssertEqual(kinds("sk-ant-api03-Zx9yW8vU7tS6rQ5pO4nM3lK2"), ["Anthropic key"])
        XCTAssertEqual(kinds("token ghp_1234567890abcdefghijABCDEFGHIJ123456"), ["GitHub token"])
        XCTAssertEqual(kinds("AKIAIOSFODNN7EXAMPLE"), ["AWS key"])
        XCTAssertEqual(kinds("AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q"), ["Google key"])
        XCTAssertEqual(kinds("sk_live_51H8abcdefGHIJKLmnop"), ["Stripe key"])
        XCTAssertEqual(kinds("-----BEGIN OPENSSH PRIVATE KEY-----"), ["Private key"])
        XCTAssertEqual(kinds("eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.dGhpc2lzYXNpZ25hdHVyZQ"), ["Token"])
    }

    func testHidesOnlyTheValueAfterPassword() {
        XCTAssertEqual(hidden("password: hunter2isgood"), ["hunter2isgood"])
        XCTAssertEqual(hidden("postgres://lee:s3cretPass@db.example.com/app"), ["s3cretPass"])
    }

    func testPlaceholdersAndPlainTextAreLeftAlone() {
        XCTAssertTrue(kinds("password: ********").isEmpty)
        XCTAssertTrue(kinds("API_KEY=process.env.OPENAI_KEY").isEmpty)
        XCTAssertTrue(kinds("Click Record to start your first take").isEmpty)
        // A git SHA is random but hex, so not a key.
        XCTAssertTrue(kinds("commit 7b4576337e539af9387e330443809970f501d182").isEmpty)
    }

    func testSouthAfricanIDAndCardsNeedAValidCheckDigit() {
        XCTAssertEqual(kinds("ID 8001015009087"), ["SA ID number"])
        XCTAssertTrue(kinds("ID 8001015009088").isEmpty)
        XCTAssertEqual(kinds("4111 1111 1111 1111"), ["Card number"])
        XCTAssertTrue(kinds("4111 1111 1111 1112").isEmpty)
    }

    func testRandomLongStringsCountAsPossibleKeys() {
        XCTAssertEqual(kinds("key Q7mZ2xR9vL4tB8nW1kJ6pF3sD0hG5cYa"), ["Possible key"])
    }
}

final class BlurPlannerTests: XCTestCase {
    private let box = FrameRect(x: 0.2, y: 0.4, width: 0.3, height: 0.03)

    func testSameSecretAcrossFramesIsOneBlurReachingPastTheScannedFrames() {
        let hit = SecretSample.Hit(kind: "OpenAI key", rect: box, fingerprint: 42)
        let samples = [2.0, 2.5, 3.0].map { SecretSample(t: $0, hits: [hit]) } + [SecretSample(t: 3.5, hits: [])]
        let blurs = BlurPlanner.propose(from: samples, interval: 0.5, sourceDuration: 10)
        XCTAssertEqual(blurs.count, 1)
        XCTAssertLessThan(blurs[0].start, 2.0)
        XCTAssertGreaterThan(blurs[0].end, 3.0)
        XCTAssertEqual(blurs[0].state, .proposed)
        XCTAssertEqual(blurs[0].kind, "OpenAI key")
        // Padded beyond the OCR box.
        XCTAssertLessThan(blurs[0].rect.x, box.x)
        XCTAssertGreaterThan(blurs[0].rect.maxY, box.maxY)
    }

    func testMovedOrDifferentSecretsAreSeparateBlurs() {
        let a = SecretSample.Hit(kind: "Token", rect: box, fingerprint: 1)
        let b = SecretSample.Hit(kind: "Token", rect: FrameRect(x: 0.2, y: 0.8, width: 0.3, height: 0.03), fingerprint: 1)
        let blurs = BlurPlanner.propose(from: [SecretSample(t: 1, hits: [a]), SecretSample(t: 1.5, hits: [b])],
                                        interval: 0.5, sourceDuration: 10)
        XCTAssertEqual(blurs.count, 2)
    }

    func testProposedBlursStillHideButRejectedOnesDont() {
        var list = BlurList()
        let blur = Blur(span: TimeSpan(start: 1, end: 3), rect: box, kind: "Password", reason: Blur.Reason.secret)
        list.propose([blur])
        XCTAssertEqual(list.track.rects(atSource: 2).count, 1)
        list.setState(.rejected, for: list.blurs[0].id)
        XCTAssertTrue(list.track.rects(atSource: 2).isEmpty)
        // Scanning again doesn't bring it back.
        XCTAssertTrue(list.propose([blur]).isEmpty)
    }

    func testEffectsMapOutputTimeToTheTake() {
        var edits = EditList(sourceDuration: 20)
        edits.add(Cut(span: TimeSpan(start: 0, end: 5)))
        let blurs = BlurList(blurs: [Blur(span: TimeSpan(start: 6, end: 8), rect: box)])
        let effects = FrameEffects.preview(zooms: ZoomList(), blurs: blurs, cursor: [], edits: edits)
        XCTAssertEqual(effects.blurs(atOutput: 1.5).count, 1) // take time 6.5
        XCTAssertTrue(effects.blurs(atOutput: 4).isEmpty)
        XCTAssertEqual(effects.viewport(atOutput: 1.5), .full)
    }
}

import XCTest
@testable import VisionOneKit

final class CameraBackgroundTests: XCTestCase {
    func testDefaultIsOffWithMatchOn() {
        let background = CameraBackground()
        XCTAssertEqual(background.style, .off)
        XCTAssertFalse(background.isOn)
        XCTAssertTrue(background.matchLight)
        XCTAssertFalse(background.moveWithMe)
        XCTAssertEqual(background.title, "Off")
    }

    func testRoundTripsThroughJSON() throws {
        var background = CameraBackground.room(.loft)
        background.moveWithMe = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try background.write(to: url)
        XCTAssertEqual(CameraBackground.read(from: url), background)
    }

    func testMissingOrBrokenFileReadsAsOff() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
        XCTAssertEqual(CameraBackground.read(from: url), .off)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let data = Data(#"{"style":"blur"}"#.utf8)
        let background = try JSONDecoder().decode(CameraBackground.self, from: data)
        XCTAssertEqual(background.style, .blur)
        XCTAssertTrue(background.matchLight)
        XCTAssertFalse(background.moveWithMe)
    }

    func testUnknownStyleReadsAsOff() throws {
        let data = Data(#"{"style":"hologram","room":"moon"}"#.utf8)
        let background = try JSONDecoder().decode(CameraBackground.self, from: data)
        XCTAssertEqual(background.style, .off)
        XCTAssertNil(background.room)
    }

    func testRoomWithoutIdOrPictureWithoutFileIsOff() {
        XCTAssertFalse(CameraBackground(style: .room).isOn)
        XCTAssertFalse(CameraBackground(style: .picture).isOn)
        XCTAssertTrue(CameraBackground(style: .picture, picture: "a.jpg").isOn)
        XCTAssertTrue(CameraBackground.room(.studio).replacesRoom)
        XCTAssertFalse(CameraBackground(style: .blur).replacesRoom)
    }

    func testWithStyleKeepsSwitchesAndClearsTheOtherSource() {
        var background = CameraBackground(style: .picture, picture: "a.jpg", matchLight: false, moveWithMe: true)
        background = background.with(style: .room, room: .gallery)
        XCTAssertEqual(background.room, .gallery)
        XCTAssertNil(background.picture)
        XCTAssertFalse(background.matchLight)
        XCTAssertTrue(background.moveWithMe)
    }

    func testPictureURLRejectsPathsOutsideTheFolder() {
        XCTAssertNil(CameraBackground(style: .picture, picture: "../secret.jpg").pictureURL)
        XCTAssertNil(CameraBackground(style: .picture, picture: ".hidden").pictureURL)
        let url = CameraBackground(style: .picture, picture: "room.jpg").pictureURL
        XCTAssertEqual(url?.lastPathComponent, "room.jpg")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "Backgrounds")
    }

    func testTakeHasBackgroundFile() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One take"))
        XCTAssertEqual(take.backgroundURL.lastPathComponent, "background.json")
    }

    // MARK: Rooms

    func testEveryRoomIsLayeredFarToNear() {
        for id in RoomID.allCases {
            let scene = id.scene
            XCTAssertEqual(scene.id, id)
            XCTAssertGreaterThanOrEqual(scene.layers.count, 2, "\(id)")
            let depths = scene.layers.map(\.depth)
            XCTAssertEqual(depths, depths.sorted(), "\(id)")
            XCTAssertTrue(depths.allSatisfy { $0 > 0 && $0 <= 1 }, "\(id)")
            XCTAssertTrue((0.5...1).contains(scene.deskLine), "\(id)")
            // The far layer fills the frame so nothing shows through.
            XCTAssertTrue(scene.layers[0].shapes.contains { $0.rect == .full }, "\(id)")
        }
    }

    func testRoomShapesStayNearTheFrame() {
        for id in RoomID.allCases {
            for shape in id.scene.layers.flatMap(\.shapes) {
                XCTAssertGreaterThan(shape.rect.width, 0)
                XCTAssertGreaterThan(shape.rect.height, 0)
                XCTAssertGreaterThanOrEqual(shape.rect.x, -0.1)
                XCTAssertGreaterThanOrEqual(shape.rect.y, -0.1)
                XCTAssertLessThanOrEqual(shape.rect.x + shape.rect.width, 1.1)
                XCTAssertLessThanOrEqual(shape.rect.y + shape.rect.height, 1.1)
                XCTAssertTrue((0...1).contains(shape.opacity))
                XCTAssertLessThanOrEqual(shape.colour, 0xFFFFFF)
            }
        }
    }

    func testRoomsNeverUseTallyOrange() {
        for id in RoomID.allCases {
            for shape in id.scene.layers.flatMap(\.shapes) {
                XCTAssertNotEqual(shape.colour, 0xFF5A1F)
                XCTAssertNotEqual(shape.colour2, 0xFF5A1F)
            }
        }
    }

    // MARK: Light match

    func testSameLightNeedsNoChange() {
        let colour = LightMatch.RGB(r: 0.5, g: 0.45, b: 0.4)
        let gains = LightMatch.gains(person: colour, room: colour)
        XCTAssertEqual(gains.r, 1, accuracy: 1e-9)
        XCTAssertEqual(gains.g, 1, accuracy: 1e-9)
        XCTAssertEqual(gains.b, 1, accuracy: 1e-9)
    }

    func testWarmRoomWarmsACoolFace() {
        let person = LightMatch.RGB(r: 0.45, g: 0.5, b: 0.6)
        let room = LightMatch.RGB(r: 0.7, g: 0.6, b: 0.45)
        let gains = LightMatch.gains(person: person, room: room)
        XCTAssertGreaterThan(gains.r, 1)
        XCTAssertLessThan(gains.b, 1)
    }

    func testGainsStayWithinTheLimit() {
        let person = LightMatch.RGB(r: 0.05, g: 0.5, b: 0.9)
        let room = LightMatch.RGB(r: 0.95, g: 0.2, b: 0.02)
        let gains = LightMatch.gains(person: person, room: room, strength: 1)
        for g in [gains.r, gains.g, gains.b] {
            XCTAssertLessThanOrEqual(g, 1 + LightMatch.limit + 1e-9)
            XCTAssertGreaterThanOrEqual(g, 1 - LightMatch.limit - 1e-9)
        }
    }

    func testBlackFrameOrZeroStrengthChangesNothing() {
        let room = LightMatch.RGB(r: 0.7, g: 0.6, b: 0.45)
        XCTAssertEqual(LightMatch.gains(person: .init(r: 0, g: 0, b: 0), room: room), .one)
        let gains = LightMatch.gains(person: .init(r: 0.4, g: 0.5, b: 0.6), room: room, strength: 0)
        XCTAssertEqual(gains.r, 1, accuracy: 1e-9)
        XCTAssertEqual(gains.b, 1, accuracy: 1e-9)
    }

    // MARK: Move with me

    func testHeadInTheMiddleMovesNothing() {
        let follower = HeadFollower()
        let offset = follower.offset(depth: 1)
        XCTAssertEqual(offset.dx, 0, accuracy: 1e-12)
        XCTAssertEqual(offset.dy, 0, accuracy: 1e-12)
    }

    func testRoomMovesAgainstTheHeadNearLayersMore() {
        var follower = HeadFollower()
        follower.update(face: (x: 1, y: 0.5), at: 0)  // First sighting snaps.
        let near = follower.offset(depth: 1), far = follower.offset(depth: 0.15)
        XCTAssertEqual(near.dx, -HeadFollower.maxShift, accuracy: 1e-12)
        XCTAssertLessThan(near.dx, far.dx)
        XCTAssertLessThan(far.dx, 0)
    }

    func testFollowerGlidesInsteadOfJumping() {
        var follower = HeadFollower(smoothing: 0.35)
        follower.update(face: (x: 0.5, y: 0.5), at: 0)
        follower.update(face: (x: 0.9, y: 0.5), at: 1.0 / 30)
        XCTAssertGreaterThan(follower.x, 0.5)
        XCTAssertLessThan(follower.x, 0.6)
        var t = 1.0 / 30
        for _ in 0..<90 {
            t += 1.0 / 30
            follower.update(face: (x: 0.9, y: 0.5), at: t)
        }
        XCTAssertEqual(follower.x, 0.9, accuracy: 0.01)
    }

    func testNoFaceKeepsTheLastSpotAndASeekSnaps() {
        var follower = HeadFollower()
        follower.update(face: (x: 0.3, y: 0.6), at: 0)
        follower.update(face: nil, at: 0.1)
        XCTAssertEqual(follower.x, 0.3, accuracy: 1e-12)
        follower.update(face: (x: 0.8, y: 0.4), at: 5)
        XCTAssertEqual(follower.x, 0.8, accuracy: 1e-12)
        follower.update(face: (x: 0.2, y: 0.4), at: 1)  // Back in time.
        XCTAssertEqual(follower.x, 0.2, accuracy: 1e-12)
    }

    func testOverscanCoversTheBiggestShift() {
        // Each side needs at least maxShift of spare room.
        XCTAssertGreaterThanOrEqual((HeadFollower.overscan - 1) / 2, HeadFollower.maxShift)
    }

    // MARK: Shadow

    func testShadowFallsAwayFromTheLight() {
        XCTAssertGreaterThan(ShadowPlan(lightFrom: .left).dx, 0)
        XCTAssertLessThan(ShadowPlan(lightFrom: .right).dx, 0)
        XCTAssertEqual(ShadowPlan(lightFrom: .front).dx, 0)
        XCTAssertLessThan(ShadowPlan(lightFrom: .front).dy, 0)
    }

    // MARK: Depth layers

    func testThresholdsSplitIntoThirds() throws {
        let values = (0..<300).map { Float($0) }
        let cuts = try XCTUnwrap(DepthLayers.thresholds(values))
        XCTAssertEqual(cuts.count, DepthLayers.depths.count - 1)
        XCTAssertEqual(Double(cuts[0]), 100, accuracy: 1)
        XCTAssertEqual(Double(cuts[1]), 199, accuracy: 1)
    }

    func testFlatOrTinyMapHasNoLayers() {
        XCTAssertNil(DepthLayers.thresholds(Array(repeating: 0.5, count: 100)))
        XCTAssertNil(DepthLayers.thresholds([0.1, 0.9]))
        XCTAssertNil(DepthLayers.thresholds(Array(repeating: .nan, count: 100)))
    }

    func testMaskMatrixIsHalfAtTheThreshold() {
        let m = DepthLayers.maskMatrix(threshold: 30, min: 10, max: 60)
        XCTAssertEqual(30 * m.scale + m.bias, 0.5, accuracy: 1e-4)
        XCTAssertGreaterThan(60 * m.scale + m.bias, 1)  // Nearest: fully in.
        XCTAssertLessThan(10 * m.scale + m.bias, 0)     // Farthest: out.
    }
}

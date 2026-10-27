import XCTest
@testable import VisionOneKit

final class AccessChecklistTests: XCTestCase {
    func testFreshInstallNeedsEverything() {
        let list = AccessChecklist(states: [:], screenAtLaunch: .notAsked)
        XCTAssertEqual(list.state(of: .screen), .notAsked)
        XCTAssertFalse(list.allGranted)
        XCTAssertFalse(list.canRecord)
        XCTAssertFalse(list.needsRestart)
    }

    func testGrantingScreenAfterLaunchNeedsRestart() {
        var list = AccessChecklist(states: [.screen: .denied, .microphone: .granted], screenAtLaunch: .denied)
        list.states[.screen] = .granted
        XCTAssertTrue(list.allGranted)
        XCTAssertTrue(list.needsRestart)
        XCTAssertFalse(list.canRecord)
    }

    func testGrantedAtLaunchIsReady() {
        let list = AccessChecklist(states: [.screen: .granted, .microphone: .granted], screenAtLaunch: .granted)
        XCTAssertTrue(list.canRecord)
        XCTAssertFalse(list.needsRestart)
    }

    func testMicrophoneOffStillLetsScreenRecord() {
        let list = AccessChecklist(states: [.screen: .granted, .microphone: .denied], screenAtLaunch: .granted)
        XCTAssertTrue(list.canRecord)
        XCTAssertFalse(list.allGranted)
    }

    func testCameraIsOptional() {
        let list = AccessChecklist(states: [.screen: .granted, .microphone: .granted, .camera: .notAsked],
                                   screenAtLaunch: .granted)
        XCTAssertTrue(AccessKind.camera.isOptional)
        XCTAssertTrue(list.allGranted)
    }
}

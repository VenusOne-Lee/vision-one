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

    func testCameraOnlyNeedsNoScreenRecording() {
        let fresh = AccessChecklist(states: [:], screenAtLaunch: .notAsked)
        XCTAssertFalse(fresh.canRecord(.screen))
        XCTAssertTrue(fresh.canRecord(.camera), "the camera is asked for when recording starts")
        let refused = AccessChecklist(states: [.camera: .denied], screenAtLaunch: .granted)
        XCTAssertFalse(refused.canRecord(.camera))
        let ready = AccessChecklist(states: [.screen: .granted, .camera: .denied], screenAtLaunch: .granted)
        XCTAssertTrue(ready.canRecord(.window))
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

final class OnboardingFlowTests: XCTestCase {
    private let fresh = AccessChecklist(states: [:], screenAtLaunch: .notAsked)
    private let ready = AccessChecklist(states: [.screen: .granted, .microphone: .granted, .camera: .granted],
                                        screenAtLaunch: .granted)

    func testFirstRunShowsWelcomeEveryPermissionAndFinish() {
        let flow = OnboardingFlow(checklist: fresh, welcomeSeen: false)
        XCTAssertEqual(flow.steps, [.welcome, .access(.screen), .access(.microphone), .access(.camera), .finish])
        XCTAssertFalse(flow.isOverview)
    }

    func testFirstRunWithoutScreenAsksOnlyMicAndCamera() {
        let flow = OnboardingFlow(checklist: fresh, welcomeSeen: false, askScreen: false)
        XCTAssertEqual(flow.steps, [.welcome, .access(.microphone), .access(.camera), .finish])
        XCTAssertTrue(flow.isReady(fresh))
        XCTAssertTrue(flow.isDone(3, current: 3, checklist: fresh))
    }

    func testMissingScreenAloneDoesNotReopenSetupWhenNotAsked() {
        let list = AccessChecklist(states: [.screen: .denied, .microphone: .granted, .camera: .denied],
                                   screenAtLaunch: .denied)
        XCTAssertTrue(OnboardingFlow(checklist: list, welcomeSeen: true, askScreen: false).isOverview)
        XCTAssertFalse(OnboardingFlow(checklist: list, welcomeSeen: true).isReady(list))
    }

    func testReturningUserLandsOnWhatIsMissing() {
        let list = AccessChecklist(states: [.screen: .granted, .microphone: .denied, .camera: .notAsked],
                                   screenAtLaunch: .granted)
        let flow = OnboardingFlow(checklist: list, welcomeSeen: true)
        XCTAssertEqual(flow.steps, [.access(.microphone), .access(.camera), .finish])
    }

    func testReturningUserIsNotAskedAgainForADeclinedCamera() {
        let list = AccessChecklist(states: [.screen: .denied, .microphone: .granted, .camera: .denied],
                                   screenAtLaunch: .denied)
        let flow = OnboardingFlow(checklist: list, welcomeSeen: true)
        XCTAssertEqual(flow.steps, [.access(.screen), .finish])
    }

    func testEverythingOnShowsTheChecklist() {
        XCTAssertTrue(OnboardingFlow(checklist: ready, welcomeSeen: true).isOverview)
        let noCamera = AccessChecklist(states: [.screen: .granted, .microphone: .granted, .camera: .denied],
                                       screenAtLaunch: .granted)
        XCTAssertTrue(OnboardingFlow(checklist: noCamera, welcomeSeen: true).isOverview)
    }

    func testEverythingOnButWelcomeUnseenStillSaysHello() {
        let flow = OnboardingFlow(checklist: ready, welcomeSeen: false)
        XCTAssertEqual(flow.steps, [.welcome, .finish])
    }

    func testGrantingTheCurrentStepMovesOn() {
        let flow = OnboardingFlow(checklist: fresh, welcomeSeen: true)
        var list = fresh
        XCTAssertEqual(flow.advanced(from: 0, checklist: list), 0)
        list.states[.screen] = .granted
        XCTAssertEqual(flow.advanced(from: 0, checklist: list), 1)
    }

    func testNextSkipsStepsGrantedInTheMeantime() {
        let flow = OnboardingFlow(checklist: fresh, welcomeSeen: false)
        var list = fresh
        list.states[.microphone] = .granted
        list.states[.camera] = .granted
        // Welcome, then Screen Recording, then straight to the finish.
        XCTAssertEqual(flow.next(after: 0, checklist: list), 1)
        XCTAssertEqual(flow.next(after: 1, checklist: list), 4)
        XCTAssertNil(flow.next(after: 4, checklist: list))
    }

    func testWelcomeAndFinishNeverAutoAdvance() {
        let flow = OnboardingFlow(checklist: ready, welcomeSeen: false)
        XCTAssertEqual(flow.advanced(from: 0, checklist: ready), 0)
        XCTAssertEqual(flow.advanced(from: 1, checklist: ready), 1)
    }

    func testDoneRingsFollowAccessNotPosition() {
        let flow = OnboardingFlow(checklist: fresh, welcomeSeen: false)
        var list = fresh
        list.states[.screen] = .granted
        // On the camera step, past a mic step that was never allowed.
        XCTAssertTrue(flow.isDone(0, current: 3, checklist: list))
        XCTAssertTrue(flow.isDone(1, current: 3, checklist: list))
        XCTAssertFalse(flow.isDone(2, current: 3, checklist: list))
        XCTAssertFalse(flow.isDone(4, current: 3, checklist: list), "Screen Recording still needs a restart")
        XCTAssertFalse(flow.isDone(9, current: 3, checklist: list))
    }
}

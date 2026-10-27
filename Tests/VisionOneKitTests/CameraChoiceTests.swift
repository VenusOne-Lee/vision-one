import XCTest
@testable import VisionOneKit

final class CameraChoiceTests: XCTestCase {
    let mac = CameraInfo(id: "mac", name: "FaceTime HD Camera", kind: .builtIn)
    let phone = CameraInfo(id: "phone", name: "Lee's iPhone Camera", kind: .iPhone, deskViewID: "desk")
    let desk = CameraInfo(id: "desk", name: "Lee's iPhone Desk View Camera", kind: .deskView)
    let cam = CameraInfo(id: "usb", name: "Logitech BRIO", kind: .external)

    var all: [CameraInfo] { [mac, cam, desk, phone] }

    func testPickerPutsIPhoneFirst() {
        XCTAssertEqual(CameraChoice.pickerOrder(all).map(\.id), ["phone", "desk", "mac", "usb"])
    }

    func testAutoFollowsTheSystem() {
        XCTAssertEqual(CameraChoice.auto.resolve(among: all, systemPreferredID: "mac"), mac)
        XCTAssertEqual(CameraChoice.auto.resolve(among: all, systemPreferredID: "phone"), phone)
    }

    func testAutoWithoutASystemPickTakesTheFirstRealCamera() {
        XCTAssertEqual(CameraChoice.auto.resolve(among: all, systemPreferredID: nil), phone)
        XCTAssertEqual(CameraChoice.auto.resolve(among: [desk, mac], systemPreferredID: "gone"), mac)
    }

    func testManualPickSticks() {
        XCTAssertEqual(CameraChoice.device(id: "desk").resolve(among: all, systemPreferredID: "mac"), desk)
    }

    func testUnpluggedPickFallsBack() {
        XCTAssertEqual(CameraChoice.device(id: "phone").resolve(among: [mac, cam], systemPreferredID: "usb"), cam)
        XCTAssertEqual(CameraChoice.device(id: "phone").resolve(among: [cam, mac], systemPreferredID: nil), mac)
    }

    func testOffAndNoCameras() {
        XCTAssertNil(CameraChoice.off.resolve(among: all, systemPreferredID: "mac"))
        XCTAssertNil(CameraChoice.auto.resolve(among: [], systemPreferredID: nil))
    }

    func testChoicesSaveAndLoad() throws {
        for choice in [CameraChoice.off, .auto, .device(id: "phone")] {
            let data = try JSONEncoder().encode(choice)
            XCTAssertEqual(try JSONDecoder().decode(CameraChoice.self, from: data), choice)
        }
    }

    func testPhoneScreenNeverFallsBack() {
        let phones = [PhoneScreenInfo(id: "a", name: "Lee's iPhone")]
        XCTAssertEqual(PhoneScreenChoice.device(id: "a").resolve(among: phones)?.name, "Lee's iPhone")
        XCTAssertNil(PhoneScreenChoice.device(id: "b").resolve(among: phones))
        XCTAssertNil(PhoneScreenChoice.off.resolve(among: phones))
    }

    func testTakeHasAPhoneTrack() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One 2026-10-27 at 10.53.12"))
        XCTAssertEqual(take.phoneURL.lastPathComponent, "phone.mov")
    }
}

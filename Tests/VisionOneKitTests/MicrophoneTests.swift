import XCTest
@testable import VisionOneKit

final class MicrophoneTests: XCTestCase {
    private let builtIn = MicrophoneOption(id: "builtin", name: "MacBook Pro Microphone", transport: .builtIn)
    private let headset = MicrophoneOption(id: "sony", name: "Distinct HQ", transport: .bluetooth)
    private let usb = MicrophoneOption(id: "usb", name: "Shure MV7", transport: .usb)

    func testBluetoothDefaultFallsBackToBuiltInMic() {
        let picked = MicrophonePicker.pick(saved: nil, available: [headset, builtIn], systemDefaultID: "sony")
        XCTAssertEqual(picked, builtIn)
    }

    func testWiredDefaultIsKept() {
        let picked = MicrophonePicker.pick(saved: nil, available: [builtIn, usb, headset], systemDefaultID: "usb")
        XCTAssertEqual(picked, usb)
    }

    func testSavedPickWinsEvenWhenBluetooth() {
        let picked = MicrophonePicker.pick(saved: "sony", available: [builtIn, headset], systemDefaultID: "builtin")
        XCTAssertEqual(picked, headset)
        XCTAssertTrue(picked?.dropsHeadphonesToCallQuality == true)
    }

    func testUnpluggedSavedPickFallsBack() {
        let picked = MicrophonePicker.pick(saved: "usb", available: [headset, builtIn], systemDefaultID: "sony")
        XCTAssertEqual(picked, builtIn)
    }

    func testOnlyBluetoothStillRecords() {
        XCTAssertEqual(MicrophonePicker.pick(saved: nil, available: [headset], systemDefaultID: "sony"), headset)
        XCTAssertNil(MicrophonePicker.pick(saved: nil, available: [], systemDefaultID: nil))
    }

    func testMenuPutsBuiltInFirstAndBluetoothLast() {
        XCTAssertEqual(MicrophonePicker.menuOrder([headset, usb, builtIn]).map(\.id), ["builtin", "usb", "sony"])
    }

    func testOldSavedChoiceStillDecodes() throws {
        let old = Data(#"{"mode":"screen","includeMicrophone":true,"includeSystemSound":false}"#.utf8)
        let choice = CaptureChoice.decoded(from: old)
        XCTAssertNil(choice.microphoneID)
        XCTAssertFalse(choice.includeSystemSound)
        var picked = choice
        picked.microphoneID = "builtin"
        XCTAssertEqual(CaptureChoice.decoded(from: try picked.encoded()).microphoneID, "builtin")
    }
}

import XCTest
@testable import VisionOneKit

final class TakeVersionsTests: XCTestCase {
    private var folder: URL!
    private var versions: TakeVersions!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("edits.json", "main edits")
        try write("sound.json", "main sound")
        versions = TakeVersions(take: Take(folder: folder))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in dir: URL? = nil) -> String? {
        try? String(contentsOf: (dir ?? folder).appendingPathComponent(name), encoding: .utf8)
    }

    func testNeverCopiedHasOneMainCut() {
        let index = versions.index()
        XCTAssertEqual(index.versions.map(\.name), ["Main cut"])
        XCTAssertEqual(index.open, "main")
        XCTAssertEqual(index.main, "main")
    }

    func testCopyParksTheMainCutAndOpensTheCopy() throws {
        let copy = try versions.tryCopy(named: "Punchier", note: "for LinkedIn")
        XCTAssertEqual(copy.id, "punchier")
        let index = versions.index()
        XCTAssertEqual(index.open, "punchier")
        XCTAssertEqual(index.main, "main")
        // Editing the copy leaves the parked main cut alone.
        try write("edits.json", "punchier edits")
        XCTAssertEqual(read("edits.json", in: versions.folder(for: "main")), "main edits")
        XCTAssertEqual(versions.folder(for: "punchier"), folder)
    }

    func testOpeningSwapsFilesBack() throws {
        try versions.tryCopy(named: "Punchier")
        try write("edits.json", "punchier edits")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("sound.json"))
        try versions.open("main")
        XCTAssertEqual(read("edits.json"), "main edits")
        XCTAssertEqual(read("sound.json"), "main sound")
        XCTAssertEqual(read("edits.json", in: versions.folder(for: "punchier")), "punchier edits")
        // The copy had no sound.json, and opening it removes the main's.
        try versions.open("punchier")
        XCTAssertEqual(read("edits.json"), "punchier edits")
        XCTAssertNil(read("sound.json"))
    }

    func testMakeMainAndDelete() throws {
        try versions.tryCopy(named: "Punchier")
        try versions.makeMain("punchier")
        XCTAssertEqual(versions.index().main, "punchier")
        XCTAssertThrowsError(try versions.delete("punchier"))
        try versions.delete("main")
        XCTAssertEqual(versions.index().versions.map(\.id), ["punchier"])
    }

    func testLockedSnapshotCantBeOpened() throws {
        let snapshot = try versions.lockSnapshot(named: "v1 exported")
        XCTAssertTrue(snapshot.locked)
        XCTAssertEqual(versions.index().open, "main")
        XCTAssertEqual(read("edits.json", in: versions.folder(for: snapshot.id)), "main edits")
        XCTAssertThrowsError(try versions.open(snapshot.id))
    }

    func testNamesAndIDsStayUnique() throws {
        XCTAssertEqual(versions.nextCopyName(), "Copy")
        try versions.tryCopy(named: "Copy")
        XCTAssertEqual(versions.nextCopyName(), "Copy 2")
        let again = try versions.tryCopy(named: "Copy")
        XCTAssertEqual(again.id, "copy-2")
        let main = try versions.tryCopy(named: "Main")
        XCTAssertEqual(main.id, "main-2")
    }
}

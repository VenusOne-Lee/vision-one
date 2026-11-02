import Foundation
import XCTest
@testable import VisionOneKit

final class VideoImportTests: XCTestCase {
    func testImportOwnsCopyAndKeepsSourceAndTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Product walkthrough.mp4")
        let bytes = Data(repeating: 42, count: 1_100_000)
        try bytes.write(to: source)
        let library = TakeLibrary(folder: root.appendingPathComponent("Library"))
        let take = try VideoImport.copy(source, into: library)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: take.screenURL), bytes)
        XCTAssertEqual(take.customTitle(), "Product walkthrough")
        XCTAssertEqual(library.takes().map { $0.folder.resolvingSymlinksInPath() }, [take.folder.resolvingSymlinksInPath()])
    }

    func testCancellationRemovesPartialTake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.mov")
        try Data(repeating: 1, count: 2_100_000).write(to: source)
        let library = TakeLibrary(folder: root.appendingPathComponent("Library"))
        var chunks = 0
        XCTAssertThrowsError(try VideoImport.copy(source, into: library) {
            chunks += 1
            if chunks == 2 { throw CancellationError() }
        })
        XCTAssertTrue(library.takes().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.folder.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}

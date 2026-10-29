import XCTest
@testable import VisionOneKit

final class AppliedTemplateTests: XCTestCase {
    func testProjectDefaultSnapshotDoesNotOverwriteUserOverridesOnReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let take = Take(folder: root)
        try AppliedTemplate.stamp(ProjectMediaDefaults(templateID: "short"), on: take)
        XCTAssertEqual(AppliedTemplate.look(for: take)?.id, "short")
        XCTAssertEqual(AppliedTemplate.presets(for: take), [.vertical])
        XCTAssertEqual(take.loadCaptionSettings().style, .wordByWord)
        var settings = take.loadCaptionSettings()
        settings.style = .subtitle
        settings.isOn = false
        settings.sizeScale = 1.4
        try take.saveCaptionSettings(settings)
        try AppliedTemplate.stamp(ProjectMediaDefaults(templateID: "demo"), on: take)
        XCTAssertEqual(take.loadCaptionSettings(), settings)
        XCTAssertEqual(AppliedTemplate.look(for: take)?.id, "short")
        try AppliedTemplate.apply(id: "demo", to: take, overwrite: true)
        XCTAssertEqual(take.loadCaptionSettings().style, .subtitle)
        XCTAssertEqual(take.loadCaptionSettings().sizeScale, 1.4)
        XCTAssertEqual(AppliedTemplate.look(for: take)?.id, "demo")
    }

    func testLegacyProjectDecodesWithoutMediaDefaults() throws {
        let data = Data(#"{"name":"Legacy"}"#.utf8)
        let project = try JSONDecoder().decode(DeskProject.self, from: data)
        XCTAssertNil(project.mediaDefaults)
        var changed = project
        changed.mediaDefaults = ProjectMediaDefaults(templateID: "tutorial", captions: false)
        var saved = project
        saved.applySettings(changed)
        XCTAssertEqual(saved.mediaDefaults, changed.mediaDefaults)
        XCTAssertEqual(try JSONDecoder().decode(DeskProject.self, from: JSONEncoder().encode(saved)), saved)
    }
}

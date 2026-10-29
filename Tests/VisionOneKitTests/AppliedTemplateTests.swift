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

extension AppliedTemplateTests {
    func testInitiallyNoTemplateStillStampsOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let take = Take(folder: root)
        try AppliedTemplate.stamp(ProjectMediaDefaults(templateID: nil), on: take)
        var user = take.loadCaptionSettings()
        user.style = .boldPop
        user.sizeScale = 1.5
        try take.saveCaptionSettings(user)
        try AppliedTemplate.stamp(ProjectMediaDefaults(templateID: "short", captions: false), on: take)
        XCTAssertNil(AppliedTemplate.look(for: take))
        XCTAssertNil(TakePlan.load(for: take))
        XCTAssertEqual(take.loadCaptionSettings(), user)
    }

    func testMissingCustomAssetRollsBackTemplateAndSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let take = Take(folder: root.appendingPathComponent("take"))
        let templates = root.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try AppliedTemplate.apply(id: "demo", to: take)
        let before = AppliedTemplate.look(for: take)
        let captions = take.loadCaptionSettings()
        var broken = TemplateLook.builtIn(id: "short")!
        broken.id = "broken"
        broken.intro = .file("missing.html")
        try broken.save(to: templates.appendingPathComponent("broken"))
        XCTAssertThrowsError(try AppliedTemplate.apply(id: "broken", to: take, overwrite: true, root: templates))
        XCTAssertEqual(AppliedTemplate.look(for: take), before)
        XCTAssertEqual(take.loadCaptionSettings(), captions)
    }
}

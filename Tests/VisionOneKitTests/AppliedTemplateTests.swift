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

extension AppliedTemplateTests {
    func testCopiedCardPaletteRespectsExplicitBrandOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let take = Take(folder: root)
        var profile = StyleScanner.profile(from: StyleInput(duration: 1, width: 1920, height: 1080, frames: []), source: "fixture")
        profile.palette = [.init(hex: "#101020", share: 0.5), .init(hex: "#F0F0E0", share: 0.5)]
        try CopiedStyle(profile: profile, copying: [.colours]).save(to: AppliedTemplate.folder(for: take))
        let base = BrandKit()
        let copied = AppliedTemplate.cardBrand(for: take, base: base)
        XCTAssertEqual(copied.paperHex, 0xF0F0E0)
        XCTAssertEqual(copied.inkHex, 0x101020)
        XCTAssertEqual(copied.ring, base.ring)
        var branded = base
        branded.paperHex = 0xEEEEEE
        XCTAssertEqual(AppliedTemplate.cardBrand(for: take, base: branded), branded)
    }
}

extension AppliedTemplateTests {
    func testCustomTemplateSnapshotOwnsReferencedCardAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let templates = root.appendingPathComponent("templates")
        let source = templates.appendingPathComponent("custom")
        let take = Take(folder: root.appendingPathComponent("take"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        var look = TemplateLook.builtIn(id: "demo")!
        look.id = "custom"
        look.intro = .file("intro.html")
        try look.save(to: source)
        try Data("<img src='images/logo.svg'>".utf8).write(to: source.appendingPathComponent("intro.html"))
        let logo = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        try logo.write(to: source.appendingPathComponent("images/logo.svg"))
        try AppliedTemplate.apply(id: "custom", to: take, root: templates)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: AppliedTemplate.folder(for: take).appendingPathComponent("images/logo.svg")), logo)
        XCTAssertEqual(AppliedTemplate.look(for: take)?.id, "custom")
    }
}

import XCTest
@testable import VisionOneKit

final class BrandKitTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("brand-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRingColoursMatchDesign() {
        XCTAssertEqual(RingColour.blue.hexString, "#1F3FBF")
        XCTAssertEqual(RingColour.gold.hexString, "#E0A21B")
        XCTAssertEqual(RingColour.green.hexString, "#1E7D4F")
        XCTAssertEqual(RingColour.black.hexString, "#121212")
        XCTAssertEqual(RingColour.allCases.count, 7)
    }

    func testMissingFileIsTheDefaultBrand() throws {
        let brand = try BrandKit.load(from: folder)
        XCTAssertEqual(brand, BrandKit())
        XCTAssertFalse(brand.intro.enabled)
        XCTAssertFalse(brand.outro.enabled)
        XCTAssertEqual(brand.fonts.display, "Bricolage Grotesque")
    }

    func testSavesAndLoads() throws {
        var brand = BrandKit(name: "Ledger Lite", tagline: "Invoices for Mzansi freelancers", site: "ledgerlite.co.za", ring: .gold)
        brand.intro.enabled = true
        brand.watermark.centerX = 0.1
        try brand.save(to: folder)
        XCTAssertEqual(try BrandKit.load(from: folder), brand)
    }

    func testOldFilesFillInDefaults() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"name":"Kasi Pay","ring":"red"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent(BrandKit.fileName))
        let brand = try BrandKit.load(from: folder)
        XCTAssertEqual(brand.name, "Kasi Pay")
        XCTAssertEqual(brand.ring, .red)
        XCTAssertEqual(brand.cta, BrandKit().cta)
        XCTAssertEqual(brand.outro, BrandKit().outro)
    }

    func testUnknownRingFallsBackToBlue() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"ring":"orange"}"#.utf8).write(to: folder.appendingPathComponent(BrandKit.fileName))
        XCTAssertEqual(try BrandKit.load(from: folder).ring, .blue)
    }

    func testBrokenFileThrows() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent(BrandKit.fileName))
        XCTAssertThrowsError(try BrandKit.load(from: folder))
    }

    func testInitialAndSite() {
        XCTAssertEqual(BrandKit(name: "  ledger").initial, "L")
        XCTAssertEqual(BrandKit(name: "").initial, "V")
        XCTAssertEqual(BrandKit(site: "https://ledgerlite.co.za/").displaySite, "ledgerlite.co.za")
    }

    func testCardDurationIsClamped() {
        XCTAssertEqual(BrandCard(enabled: true, duration: 30).clampedDuration, 8)
        XCTAssertEqual(BrandCard(enabled: true, duration: 0).clampedDuration, 1)
    }

    func testLogoStaysInsideTheBrandFolder() {
        let brand = BrandKit(logo: "../../secret.png")
        XCTAssertEqual(brand.logoURL(in: folder)?.lastPathComponent, "secret.png")
        XCTAssertEqual(brand.logoURL(in: folder)?.deletingLastPathComponent().standardizedFileURL.path,
                       folder.standardizedFileURL.path)
    }

    func testImportsLogo() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("logo-\(UUID().uuidString).PNG")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var brand = BrandKit()
        try brand.importLogo(from: source, into: folder)
        XCTAssertEqual(brand.logo, "logo.png")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(brand.logoURL(in: folder))), Data([1, 2, 3]))

        // A second import replaces the first.
        try brand.importLogo(from: source, into: folder)
        XCTAssertEqual(brand.logo, "logo.png")
    }
}

final class TemplateLookTests: XCTestCase {
    func testBuiltInsCoverTheV02Purposes() {
        let ids = Set(TemplateLook.builtIn.map(\.purposeID))
        for purpose in ["launch", "demo", "short", "tutorial", "bugReport", "update", "talkingHead"] {
            XCTAssertTrue(ids.contains(purpose), purpose)
        }
        XCTAssertEqual(Set(TemplateLook.builtIn.map(\.id)).count, TemplateLook.builtIn.count)
    }

    func testBugReportHasNoCardsAndShortIsVertical() throws {
        let bug = try XCTUnwrap(TemplateLook.builtIn(id: "bugReport"))
        XCTAssertEqual(bug.intro, .off)
        XCTAssertEqual(bug.outro, .off)
        XCTAssertNil(bug.captionStyle)

        let short = try XCTUnwrap(TemplateLook.builtIn(purposeID: "short"))
        XCTAssertEqual(short.pickedFormats, [.vertical])
        XCTAssertEqual(short.reframe(for: .vertical), .follow)
        XCTAssertEqual(short.reframe(for: .landscape), .fit)
    }

    func testReadsAHandWrittenManifest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tpl-\(UUID().uuidString)/client", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let json = #"""
        {"title":"Client walkthrough","intro":"intro.html","outro":"none",
         "formats":[{"format":"landscape"},{"format":"vertical","suggested":true}],
         "captionStyle":"subtitle"}
        """#
        try Data(json.utf8).write(to: folder.appendingPathComponent(TemplateLook.manifestName))

        let look = try TemplateLook.load(from: folder)
        XCTAssertEqual(look.id, "client")
        XCTAssertEqual(look.purposeID, "client")
        XCTAssertEqual(look.intro, .file("intro.html"))
        XCTAssertEqual(look.outro, .off)
        XCTAssertEqual(look.reframe(for: .landscape), .fit)
        XCTAssertEqual(look.reframe(for: .vertical), .follow)
        XCTAssertEqual(look.pickedFormats, [.landscape])
        XCTAssertEqual(look.captionStyle, .subtitle)
        XCTAssertEqual(TemplateLook.loadAll(in: folder.deletingLastPathComponent()).map(\.id), ["client"])
    }

    func testRoundTrips() throws {
        for look in TemplateLook.builtIn {
            let data = try JSONEncoder().encode(look)
            XCTAssertEqual(try JSONDecoder().decode(TemplateLook.self, from: data), look)
        }
    }

    func testCardFilesStayInsideTheTemplate() {
        let folder = URL(fileURLWithPath: "/tmp/templates/launch")
        XCTAssertEqual(TemplateLook.cardURL(.file("intro.html"), in: folder)?.path, "/tmp/templates/launch/intro.html")
        XCTAssertEqual(TemplateLook.cardURL(.file("cards/outro.html"), in: folder)?.path, "/tmp/templates/launch/cards/outro.html")
        XCTAssertNil(TemplateLook.cardURL(.file("../other/intro.html"), in: folder))
        XCTAssertNil(TemplateLook.cardURL(.file("/etc/passwd"), in: folder))
        XCTAssertNil(TemplateLook.cardURL(.file("intro.js"), in: folder))
        XCTAssertNil(TemplateLook.cardURL(.brand, in: folder))
    }
}

final class TemplatePlanTests: XCTestCase {
    func testNoCardsByDefault() {
        let plan = TemplatePlan(brand: BrandKit(), bodyDuration: 30)
        XCTAssertFalse(plan.hasCards)
        XCTAssertEqual(plan.body, 0..<30)
        XCTAssertEqual(plan.duration, 30)
    }

    func testIntroAndOutroWrapTheBody() throws {
        var brand = BrandKit()
        brand.intro = BrandCard(enabled: true, duration: 2.5)
        brand.outro = BrandCard(enabled: true, duration: 4)
        let plan = TemplatePlan(brand: brand, bodyDuration: 10)
        XCTAssertEqual(plan.intro, 0..<2.5)
        XCTAssertEqual(plan.body, 2.5..<12.5)
        XCTAssertEqual(plan.outro, 12.5..<16.5)
        XCTAssertEqual(plan.duration, 16.5)

        XCTAssertEqual(plan.part(at: 1), .intro)
        XCTAssertEqual(plan.part(at: 3), .body)
        XCTAssertEqual(plan.part(at: 13), .outro)
        XCTAssertNil(plan.bodyTime(forOutput: 1))
        XCTAssertEqual(try XCTUnwrap(plan.bodyTime(forOutput: 3)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(plan.cardTime(forOutput: 13)), 0.5, accuracy: 1e-9)
        XCTAssertNil(plan.cardTime(forOutput: 5))
    }

    func testTemplateCanTurnCardsOff() {
        var brand = BrandKit()
        brand.intro.enabled = true
        brand.outro.enabled = true
        let plan = TemplatePlan(brand: brand, look: TemplateLook.builtIn(id: "bugReport"), bodyDuration: 10)
        XCTAssertFalse(plan.hasCards)

        let short = TemplatePlan(brand: brand, look: TemplateLook.builtIn(id: "short"), bodyDuration: 10)
        XCTAssertNil(short.intro)
        XCTAssertNotNil(short.outro)
    }

    func testEmptyBodyHasNoCards() {
        var brand = BrandKit()
        brand.intro.enabled = true
        XCTAssertFalse(TemplatePlan(brand: brand, bodyDuration: 0).hasCards)
    }
}

final class CardScriptTests: XCTestCase {
    func testVariablesComeFromTheBrand() {
        let brand = BrandKit(name: "Ledger Lite", tagline: "Invoices", site: "https://ledgerlite.co.za", ring: .pink)
        let vars = CardVariables(brand: brand, logo: Data([0xFF]), logoType: "image/png")
        XCTAssertEqual(vars.text["product"], "Ledger Lite")
        XCTAssertEqual(vars.text["site"], "ledgerlite.co.za")
        XCTAssertEqual(vars.text["initial"], "L")
        XCTAssertEqual(vars.css["--ring"], "#C2306E")
        XCTAssertEqual(vars.css["--paper"], "#FFFFFF")
        XCTAssertEqual(vars.logoDataURL, "data:image/png;base64,/w==")
        XCTAssertEqual(vars.css["--display-font"], "\"Bricolage Grotesque\", ui-sans-serif, system-ui, sans-serif")
    }

    func testFontNamesCantBreakOutOfCSS() {
        let stack = CardVariables.fontStack("Evil\"; } body { display:none", fallback: "serif")
        XCTAssertFalse(stack.contains(";"))
        XCTAssertFalse(stack.contains("{"))
        XCTAssertEqual(CardVariables.fontStack("", fallback: "serif"), "serif")
    }

    func testScriptsSeekEveryKindOfAnimation() {
        XCTAssertTrue(CardScript.seek.contains("getAnimations()"))
        XCTAssertTrue(CardScript.seek.contains("__timelines"))
        XCTAssertTrue(CardScript.seek.contains("data-start"))
        XCTAssertTrue(CardScript.prepare.contains("textContent"))
        XCTAssertFalse(CardScript.prepare.contains("innerHTML"))
    }

    func testFrameTimes() {
        let times = CardScript.frameTimes(duration: 2, frameRate: 30)
        XCTAssertEqual(times.count, 60)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last ?? 0, 59.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(CardScript.frameTimes(duration: 0, frameRate: 30).count, 1)
    }

    func testMimeTypes() {
        XCTAssertEqual(CardVariables.mimeType(forExtension: "SVG"), "image/svg+xml")
        XCTAssertEqual(CardVariables.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(CardVariables.mimeType(forExtension: "png"), "image/png")
    }
}

extension CardScriptTests {
    func testOfflineRulesUseLiteralSchemesWithoutDisjunction() throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(CardScript.blockNetworkRules.utf8)) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: String])?["url-filter"] }
        XCTAssertEqual(filters, ["^http://", "^https://", "^ws://", "^wss://", "^ftp://", "^ftps://"])
        XCTAssertTrue(rules.allSatisfy { ($0["action"] as? [String: String])?["type"] == "block" })
    }

    func testPaintedCardCanEndWithFlatFrame() {
        var evidence = CardPaintEvidence()
        var painted = Data(repeating: 255, count: 8192)
        painted[8188] = 0
        evidence.observe(painted)
        evidence.observe(Data(repeating: 255, count: 8192))
        XCTAssertTrue(evidence.hasPaint)
    }

    func testOnlyFlatFramesHaveNoPaintEvidence() {
        var evidence = CardPaintEvidence()
        evidence.observe(Data(repeating: 0, count: 8192))
        evidence.observe(Data(repeating: 255, count: 8192))
        XCTAssertFalse(evidence.hasPaint)
    }
}

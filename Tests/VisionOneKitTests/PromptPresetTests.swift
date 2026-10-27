import XCTest
@testable import VisionOneKit

final class PromptSlotTests: XCTestCase {
    func testReadsHeadingsTheWayPeopleTypeThem() {
        XCTAssertEqual(PromptSlot(heading: "House style"), .houseStyle)
        XCTAssertEqual(PromptSlot(heading: "house STYLE"), .houseStyle)
        XCTAssertEqual(PromptSlot(heading: "Brand"), .houseStyle)
        XCTAssertEqual(PromptSlot(heading: "Title + post"), .titleAndPost)
        XCTAssertEqual(PromptSlot(heading: "Title and Post"), .titleAndPost)
        XCTAssertEqual(PromptSlot(heading: "Title & post"), .titleAndPost)
        XCTAssertEqual(PromptSlot(heading: "B-roll"), .bRoll)
        XCTAssertEqual(PromptSlot(heading: "b roll"), .bRoll)
        XCTAssertEqual(PromptSlot(heading: "Sound effects"), .soundEffects)
        XCTAssertEqual(PromptSlot(heading: "Title"), .title)
        XCTAssertEqual(PromptSlot(heading: "Clip"), .clip)
        XCTAssertNil(PromptSlot(heading: "Weather"))
    }

    func testEveryHeadingRoundTrips() {
        for slot in PromptSlot.allCases {
            XCTAssertEqual(PromptSlot(heading: slot.heading), slot, slot.heading)
        }
    }

    func testAgentKeysMatchTheAgentBrief() {
        XCTAssertEqual(PromptSlot.titleAndPost.agentKey, "post")
        XCTAssertEqual(PromptSlot.hook.agentKey, "hook")
        XCTAssertEqual(PromptSlot.chapters.agentKey, "chapters")
        XCTAssertEqual(PromptSlot.clip.agentKey, "clip")
    }
}

final class PromptDocumentTests: XCTestCase {
    let sample = """
    ---
    name: Mzansi warm
    energy: lively
    ---

    ## House style
    Talk like a South African builder.
    Plain words.

    ## Hook
    Open on the problem {audience} feels.

    ## Weather
    Sunny in Joburg.
    """

    func testParsesFrontMatterAndSections() {
        let doc = PromptDocument(markdown: sample)
        XCTAssertEqual(doc.value(for: "name"), "Mzansi warm")
        XCTAssertEqual(doc.value(for: "Energy"), "lively")
        XCTAssertEqual(doc.sections.map(\.heading), ["House style", "Hook", "Weather"])
        XCTAssertEqual(doc.text(for: .houseStyle), "Talk like a South African builder.\nPlain words.")
        XCTAssertEqual(doc.text(for: .hook), "Open on the problem {audience} feels.")
        XCTAssertNil(doc.text(for: .outro))
    }

    func testIgnoresTextBeforeTheFirstHeadingAndHeadingsInCode() {
        let doc = PromptDocument(markdown: """
        # Launch video prompts
        Intro text nobody needs.

        ## Body
        Explain it.
        ```
        ## not a heading
        ```
        """)
        XCTAssertTrue(doc.frontMatter.isEmpty)
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertEqual(doc.text(for: .body), "Explain it.\n```\n## not a heading\n```")
    }

    func testEmptySectionMeansUseTheDefault() {
        let doc = PromptDocument(markdown: "## Hook\n\n## Outro\nBye.")
        XCTAssertNil(doc.text(for: .hook))
        XCTAssertEqual(doc.text(for: .outro), "Bye.")
    }

    func testHandlesWindowsLineEndingsAndQuotedValues() {
        let doc = PromptDocument(markdown: "---\r\nname: \"Client: walkthroughs\"\r\n---\r\n## Hook\r\nHi.\r\n")
        XCTAssertEqual(doc.value(for: "name"), "Client: walkthroughs")
        XCTAssertEqual(doc.text(for: .hook), "Hi.")
    }

    func testRoundTrips() {
        let doc = PromptDocument(markdown: sample)
        XCTAssertEqual(PromptDocument(markdown: doc.markdown), doc)
    }
}

final class PromptPresetTests: XCTestCase {
    func testReadsAPresetFile() {
        let preset = PromptPreset(markdown: """
        ---
        name: Mzansi warm
        energy: Lively
        ---
        ## House style
        Plain words.
        ## Hook
        Problem first.
        ## Future part
        Kept.
        """)
        XCTAssertEqual(preset.name, "Mzansi warm")
        XCTAssertEqual(preset.energy, "lively")
        XCTAssertEqual(preset[.houseStyle], "Plain words.")
        XCTAssertEqual(preset.changedSlots, [.houseStyle, .hook])
        XCTAssertEqual(preset.unknownSections.map(\.heading), ["Future part"])
        XCTAssertFalse(preset.isBuiltIn)
    }

    func testFallsBackToTheFileName() {
        let preset = PromptPreset(markdown: "## Hook\nHi.", fallbackName: "Thabo's demo voice")
        XCTAssertEqual(preset.name, "Thabo's demo voice")
        XCTAssertNil(preset.energy)
    }

    func testWritesPartsInTemplateOrderAndKeepsUnknownSections() {
        var preset = PromptPreset(name: "Mine")
        preset[.outro] = "Bye."
        preset[.hook] = "  Hi.  "
        preset.unknownSections = [.init(heading: "Future part", text: "Kept.")]
        XCTAssertEqual(preset.markdown, """
        ---
        name: Mine
        ---

        ## Hook
        Hi.

        ## Outro
        Bye.

        ## Future part
        Kept.

        """)
        let back = PromptPreset(markdown: preset.markdown)
        XCTAssertEqual(back, preset)
    }

    func testClearingAPartRemovesIt() {
        var preset = PromptPreset(name: "Mine", prompts: [.hook: "Hi."])
        preset[.hook] = "   "
        XCTAssertNil(preset[.hook])
        XCTAssertTrue(preset.changedSlots.isEmpty)
    }

    func testFileNamesAreSafe() {
        XCTAssertEqual(PromptPreset(name: "Client: walk/throughs").fileName, "Client- walk-throughs.md")
        XCTAssertEqual(PromptPreset(name: "  ..  ").fileName, "Preset.md")
    }

    func testBuiltInsAreMarkedAndRoundTrip() {
        XCTAssertEqual(PromptPreset.builtIn.map(\.name), ["Straight talk", "Mzansi warm", "Launch hype"])
        for preset in PromptPreset.builtIn {
            XCTAssertTrue(preset.isBuiltIn)
            XCTAssertNotNil(preset[.houseStyle])
            var back = PromptPreset(markdown: preset.markdown)
            back.isBuiltIn = true
            XCTAssertEqual(back, preset)
        }
    }
}

final class PromptResolverTests: XCTestCase {
    let template = PromptDocument(markdown: """
    ## House style
    Template voice.
    ## Hook
    Template hook for {product}.
    ## Outro
    Template outro.
    """)

    let vars = PromptVariables(product: "Kasi Pay", audience: "spaza owners", site: "kasipay.co.za", cta: "Try it free", ring: "blue")

    func testTemplateDefaultWhenNothingElse() {
        let r = PromptResolver.resolve(slot: .hook, template: template, variables: vars)
        XCTAssertEqual(r.source, .template)
        XCTAssertEqual(r.system, "Template voice.")
        XCTAssertEqual(r.instruction, "Template hook for Kasi Pay.")
        XCTAssertEqual(r.text, "Template voice.\n\nTemplate hook for Kasi Pay.")
    }

    func testPresetBeatsTemplateAndItsHouseStyleWins() {
        let preset = PromptPreset(name: "Mzansi warm", prompts: [.houseStyle: "Talk to {audience}.", .hook: "Problem first."])
        let hook = PromptResolver.resolve(slot: .hook, template: template, preset: preset, variables: vars)
        XCTAssertEqual(hook.source, .preset(name: "Mzansi warm"))
        XCTAssertEqual(hook.system, "Talk to spaza owners.")
        XCTAssertEqual(hook.instruction, "Problem first.")

        // A part the preset leaves out still uses the template, under the preset's house style.
        let outro = PromptResolver.resolve(slot: .outro, template: template, preset: preset, variables: vars)
        XCTAssertEqual(outro.source, .template)
        XCTAssertEqual(outro.system, "Talk to spaza owners.")
        XCTAssertEqual(outro.instruction, "Template outro.")
    }

    func testMomentBeatsEverything() {
        let preset = PromptPreset(name: "P", prompts: [.hook: "Preset hook."])
        let r = PromptResolver.resolve(slot: .hook, template: template, preset: preset, moment: "  Make it funnier. ", variables: vars)
        XCTAssertEqual(r.source, .moment)
        XCTAssertEqual(r.instruction, "Make it funnier.")
        XCTAssertEqual(r.system, "Template voice.")
    }

    func testNothingAnywhere() {
        let r = PromptResolver.resolve(slot: .music)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.source, .none)
        XCTAssertEqual(r.text, "")
    }

    func testMissingVariablesStayVisibleAndAreListed() {
        let preset = PromptPreset(name: "P", prompts: [.hook: "For {audience} at {site} by {founder}."])
        let r = PromptResolver.resolve(slot: .hook, preset: preset, variables: PromptVariables(audience: "builders", site: " "))
        XCTAssertEqual(r.instruction, "For builders at {site} by {founder}.")
        XCTAssertEqual(r.missingVariables, ["site", "founder"])
    }

    func testResolveAllCoversEveryPartButHouseStyle() {
        let all = PromptResolver.resolveAll(template: template, variables: vars)
        XCTAssertEqual(all.count, PromptSlot.allCases.count - 1)
        XCTAssertFalse(all.contains { $0.slot == .houseStyle })
    }
}

final class PromptVariablesTests: XCTestCase {
    func testFillsKnownNamesAnyCase() {
        let v = PromptVariables(product: "Vision One", cta: "Download it")
        XCTAssertEqual(v.fill("Try {product}. {CTA}!"), "Try Vision One. Download it!")
    }

    func testLeavesBracesThatAreNotVariables() {
        let v = PromptVariables(product: "X")
        XCTAssertEqual(v.fill("JSON like {\"a\": 1} and { product } and {product"), "JSON like {\"a\": 1} and { product } and {product")
        XCTAssertEqual(v.fill("{{product}}"), "{X}")
        XCTAssertEqual(v.fill("{product}\n{"), "X\n{")
    }
}

final class PresetLibraryTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testEmptyFolderListsBuiltIns() {
        let library = PresetLibrary(folder: folder)
        XCTAssertTrue(library.load().isEmpty)
        XCTAssertEqual(library.all().map(\.name), PromptPreset.builtIn.map(\.name))
    }

    func testSavesLoadsAndDeletes() throws {
        let library = PresetLibrary(folder: folder)
        let url = try library.save(PromptPreset(name: "Client walkthroughs", energy: "calm", prompts: [.hook: "Hi."]))
        XCTAssertEqual(url.lastPathComponent, "Client walkthroughs.md")
        let loaded = library.load()
        XCTAssertEqual(loaded.map(\.name), ["Client walkthroughs"])
        XCTAssertEqual(loaded.first?[.hook], "Hi.")
        try library.delete(loaded[0])
        XCTAssertTrue(library.load().isEmpty)
    }

    func testSavingABuiltInMakesYourCopyThatReplacesIt() throws {
        let library = PresetLibrary(folder: folder)
        var mine = PromptPreset.builtIn[1]
        mine[.hook] = "My own hook."
        try library.save(mine)
        let all = library.all()
        XCTAssertEqual(all.filter { $0.name == "Mzansi warm" }.count, 1)
        let copy = try XCTUnwrap(all.first { $0.name == "Mzansi warm" })
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy[.hook], "My own hook.")
    }

    func testUniqueNames() {
        let library = PresetLibrary(folder: folder)
        let presets = [PromptPreset(name: "A"), PromptPreset(name: "A copy")]
        XCTAssertEqual(library.uniqueName(startingFrom: "B", among: presets), "B")
        XCTAssertEqual(library.uniqueName(startingFrom: "a", among: presets), "a copy 2")
    }
}

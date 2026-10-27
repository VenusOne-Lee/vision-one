import XCTest
@testable import VisionOneKit

final class VersionsTests: XCTestCase {
    // MARK: Reading lists

    func testHeaderRowInAnyOrder() {
        let list = RecipientList.parse("""
        Email,Company,Name
        thandi@example.co.za,Joburg Taxi Association,Thandi Mokoena
        """)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.recipients[0].name, "Thandi Mokoena")
        XCTAssertEqual(list.recipients[0].company, "Joburg Taxi Association")
        XCTAssertEqual(list.recipients[0].email, "thandi@example.co.za")
    }

    func testGuessingWithoutAHeader() {
        let list = RecipientList.parse("""
        Thandi Mokoena, Joburg Taxi Association, thandi@example.co.za
        Pieter van Wyk <pieter@example.co.za>
        sipho.dlamini@example.co.za
        """)
        XCTAssertEqual(list.recipients.map(\.name), ["Thandi Mokoena", "Pieter van Wyk", "Sipho Dlamini"])
        XCTAssertEqual(list.recipients[1].email, "pieter@example.co.za")
        XCTAssertEqual(list.recipients[2].company, "")
        XCTAssertEqual(list.recipients.map(\.id), [0, 1, 2])
    }

    func testTabsAndSemicolonsAndQuotes() {
        let tabs = RecipientList.parse("Sipho Dlamini\tBellville Rank\nLerato Khumalo\tSoweto Kota")
        XCTAssertEqual(tabs.recipients.map(\.company), ["Bellville Rank", "Soweto Kota"])

        let excel = RecipientList.parse("\u{FEFF}Naam;Maatskappy\r\nAnnelie Botha;\"Botha, Smit & Seuns\"\r\n")
        XCTAssertEqual(excel.count, 1)
        XCTAssertEqual(excel.recipients[0].name, "Annelie Botha")
        XCTAssertEqual(excel.recipients[0].company, "Botha, Smit & Seuns")
    }

    func testFirstAndLastColumnsAndLanguage() {
        let list = RecipientList.parse("""
        first name,surname,language,city
        Zanele,Ndlovu,zu,Durban
        """)
        XCTAssertEqual(list.recipients[0].name, "Zanele Ndlovu")
        XCTAssertEqual(list.recipients[0].language, .zulu)
        XCTAssertEqual(list.recipients[0].extra["city"], "Durban")
    }

    func testRepeatsBlanksAndProblems() {
        let list = RecipientList.parse("""
        name,company,email
        Thandi Mokoena,JTA,thandi@example.co.za

        Thandi M,JTA,THANDI@example.co.za
        ,Nobody Inc,
        """)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.repeats, 1)
        XCTAssertEqual(list.problems.count, 1)
        XCTAssertEqual(list.problems[0].line, 5)
    }

    func testLimit() {
        let text = (1...(RecipientList.maxRecipients + 5)).map { "Person \($0)" }.joined(separator: "\n")
        let list = RecipientList.parse(text)
        XCTAssertEqual(list.count, RecipientList.maxRecipients)
        XCTAssertEqual(list.overLimit, 5)
    }

    func testFirstNameSkipsTitles() {
        XCTAssertEqual(Recipient(id: 0, name: "Dr Sipho Dlamini").firstName, "Sipho")
        XCTAssertEqual(Recipient(id: 0, name: "Mnr. Pieter van Wyk").firstName, "Pieter")
        XCTAssertEqual(Recipient(id: 0, name: "Thandi").firstName, "Thandi")
    }

    // MARK: Card lines

    func testCardLinesFillAndFallBack() {
        let thandi = Recipient(id: 0, name: "Thandi Mokoena", company: "JTA")
        let nobody = Recipient(id: 1, name: "", company: "")
        XCTAssertEqual(CardLine.headline.filled(for: thandi), "Made for Thandi")
        XCTAssertEqual(CardLine.headline.filled(for: nobody), "Made for you")
        XCTAssertEqual(CardLine.subline.filled(for: thandi), "JTA")
        XCTAssertEqual(CardLine("{company|your team}").filled(for: nobody), "your team")
    }

    func testEmptyFieldDropsItsLeaningWord() {
        let sipho = Recipient(id: 0, name: "Sipho Dlamini")
        XCTAssertEqual(CardLine("Hi {first name} from {company}").filled(for: sipho), "Hi Sipho")
        XCTAssertEqual(CardLine("{name} · {company}").filled(for: sipho), "Sipho Dlamini")
        XCTAssertEqual(CardLine("{product} for {company}").filled(for: sipho, product: "Vision One"), "Vision One")
    }

    func testFieldsAndExtraColumns() {
        let line = CardLine("{first name}, see {city|your city}")
        XCTAssertEqual(line.fields, ["first name", "city"])
        let zanele = Recipient(id: 0, name: "Zanele Ndlovu", extra: ["city": "Durban"])
        XCTAssertEqual(line.filled(for: zanele), "Zanele, see Durban")
    }

    // MARK: Planning

    func testFileNamesAreSafeAndUnique() {
        let list = RecipientList(recipients: [
            Recipient(id: 0, name: "Thandi Mokoena", company: "JTA/Joburg"),
            Recipient(id: 1, name: "Thandi Mokoena", company: "JTA/Joburg", email: "other@example.co.za"),
            Recipient(id: 2, name: "", company: ""),
        ])
        let plan = VersionPlanner.plan(list, settings: VersionSettings())
        XCTAssertEqual(plan.map(\.fileName), ["Thandi Mokoena - JTAJoburg.mp4", "Thandi Mokoena - JTAJoburg 2.mp4",
                                             "Version 3.mp4"])
    }

    func testCaptionLanguageOnlyWhenTheTakeHasIt() {
        let list = RecipientList(recipients: [
            Recipient(id: 0, name: "Zanele", language: .zulu),
            Recipient(id: 1, name: "Annelie", language: .afrikaans),
        ])
        let plan = VersionPlanner.plan(list, settings: VersionSettings(), available: [.zulu])
        XCTAssertEqual(plan.map(\.captionLanguage), [.zulu, nil])
        var off = VersionSettings()
        off.captionsInTheirLanguage = false
        XCTAssertEqual(VersionPlanner.plan(list, settings: off, available: [.zulu]).map(\.captionLanguage), [nil, nil])
    }

    func testCSVIsSafeForSpreadsheets() {
        let list = RecipientList(recipients: [Recipient(id: 0, name: "=HYPERLINK(\"x\")", company: "A, B")])
        let plan = VersionPlanner.plan(list, settings: VersionSettings())
        let csv = VersionPlanner.csv(plan, folder: URL(fileURLWithPath: "/tmp/Versions"), status: [0: "made"])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines[0], "name,first name,company,email,language,file,status")
        XCTAssertTrue(lines[1].hasPrefix("\"'=HYPERLINK(\"\"x\"\")\""))
        XCTAssertTrue(lines[1].contains("\"A, B\""))
        XCTAssertTrue(lines[1].hasSuffix(",made"))
    }

    func testSettingsRoundTripAndClamp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)
        XCTAssertEqual(take.loadVersionSettings(), VersionSettings())
        var settings = VersionSettings(headline: CardLine("Sawubona {first name}"), cardDuration: 20)
        settings.titleCard = false
        try take.saveVersionSettings(settings)
        XCTAssertEqual(take.loadVersionSettings(), settings)
        XCTAssertEqual(settings.clampedDuration, VersionSettings.durationRange.upperBound)
        XCTAssertEqual(VersionPlanner.folder(for: take).lastPathComponent, "Versions")
    }

    func testEstimateAndReceipt() {
        XCTAssertEqual(VersionPlanner.estimatedSeconds(count: 10, videoSeconds: 60, cardSeconds: 2.5, speed: 2.5), 250)
        XCTAssertEqual(AgentReceipt.versions(made: 1, failed: 0), "Made 1 version. Nothing left your Mac.")
        XCTAssertEqual(AgentReceipt.versions(made: 38, failed: 2), "Made 38 versions. 2 didn't make it; versions.csv says why.")
    }
}

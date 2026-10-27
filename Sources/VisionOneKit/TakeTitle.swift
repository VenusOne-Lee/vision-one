import Foundation

/// A name the builder gives a take ("Launch video for Kasi Eats"). The
/// folder keeps its date name, so nothing that points at the take breaks;
/// the title lives beside it in title.txt.
extension Take {
    public var titleURL: URL { folder.appendingPathComponent("title.txt") }

    /// The builder's own name for the take, or nil when it has none.
    public var customTitle: String? {
        guard let data = try? Data(contentsOf: titleURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let title = Take.cleanTitle(text)
        return title.isEmpty ? nil : title
    }

    /// The custom title, else "Today at 14:41".
    public func displayTitle(now: Date = Date(), calendar: Calendar = .current) -> String {
        customTitle ?? shortLabel(now: now, calendar: calendar)
    }

    /// Saves a new title. An empty one goes back to the date.
    public func setTitle(_ title: String, fileManager: FileManager = .default) throws {
        let clean = Take.cleanTitle(title)
        if clean.isEmpty {
            if fileManager.fileExists(atPath: titleURL.path) { try fileManager.removeItem(at: titleURL) }
        } else {
            try Data(clean.utf8).write(to: titleURL, options: .atomic)
        }
    }

    /// One line, trimmed, at most 80 characters.
    static func cleanTitle(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}

extension TakePlan {
    /// Remembers what a new take is for: Home's pick, saved into the take
    /// when recording stops so later changes on Home don't rewrite it.
    /// Leaves an existing plan alone, and writes nothing for "Just record"
    /// (no pick) or an unknown id. Returns the plan it wrote, if any.
    @discardableResult
    public static func stamp(_ take: Take, purposeID: String?,
                             fileManager: FileManager = .default) throws -> TakePlan? {
        guard !fileManager.fileExists(atPath: take.planURL.path),
              let id = purposeID, let purpose = Purpose.named(id) else { return nil }
        let plan = TakePlan(purpose: purpose)
        try plan.write(for: take)
        return plan
    }
}

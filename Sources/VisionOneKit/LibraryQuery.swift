import Foundation

extension Take {
    /// A name the builder typed for the take, kept beside the recording.
    /// The folder keeps its dated name, so nothing that reads it breaks.
    public var titleURL: URL { folder.appendingPathComponent("title.txt") }

    /// The typed name, or nil when there isn't one.
    public func customTitle(fileManager: FileManager = .default) -> String? {
        guard let data = fileManager.contents(atPath: titleURL.path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let title = Self.cleanTitle(text)
        return title.isEmpty ? nil : title
    }

    /// Saves a typed name. Blank goes back to the date.
    public func setTitle(_ title: String, fileManager: FileManager = .default) throws {
        let clean = Self.cleanTitle(title)
        if clean.isEmpty {
            if fileManager.fileExists(atPath: titleURL.path) {
                try fileManager.removeItem(at: titleURL)
            }
        } else {
            try Data(clean.utf8).write(to: titleURL, options: .atomic)
        }
    }

    /// The typed name, else "Today at 14:41".
    public func displayTitle(now: Date = Date(), calendar: Calendar = .current,
                             fileManager: FileManager = .default) -> String {
        customTitle(fileManager: fileManager) ?? shortLabel(now: now, calendar: calendar)
    }

    /// One line, no surrounding space, at most 120 characters.
    static func cleanTitle(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(120))
    }
}

/// One take as the Library lists it: what it's called, when, how long,
/// where it's up to, and its words for search.
public struct LibraryItem: Equatable, Sendable {
    public var take: Take
    public var title: String
    public var recordedAt: Date?
    public var duration: Double?
    public var isExported: Bool
    /// Cuts auto-clean proposed that still wait for a yes or no.
    public var suggestedCuts: Int
    /// The transcript's words, when there is one.
    public var transcriptText: String?
    /// What it's for ("Demo"), from plan.json; nil for Just record.
    public var purposeTitle: String?

    public init(take: Take, title: String, recordedAt: Date? = nil, duration: Double? = nil,
                isExported: Bool = false, suggestedCuts: Int = 0, transcriptText: String? = nil,
                purposeTitle: String? = nil) {
        self.take = take
        self.title = title
        self.recordedAt = recordedAt
        self.duration = duration
        self.isExported = isExported
        self.suggestedCuts = suggestedCuts
        self.transcriptText = transcriptText
        self.purposeTitle = purposeTitle
    }

    public var needsReview: Bool { suggestedCuts > 0 }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case newest, oldest, longest, title

    public var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .longest: return "Longest first"
        case .title: return "Name"
        }
    }
}

public enum LibraryFilter: String, CaseIterable, Sendable {
    case all, toReview, notExported, exported

    public var label: String {
        switch self {
        case .all: return "All"
        case .toReview: return "To review"
        case .notExported: return "Not exported"
        case .exported: return "Exported"
        }
    }

    public func includes(_ item: LibraryItem) -> Bool {
        switch self {
        case .all: return true
        case .toReview: return item.needsReview
        case .notExported: return !item.isExported
        case .exported: return item.isExported
        }
    }
}

/// Search, filter and sort for the Library. Search matches every word
/// typed, in the title, what it's for or anything said in the take, ignoring case and
/// accents, so "demo login" finds the take where you said both.
public struct LibraryQuery: Equatable, Sendable {
    public var search: String
    public var filter: LibraryFilter
    public var sort: LibrarySort

    public init(search: String = "", filter: LibraryFilter = .all, sort: LibrarySort = .newest) {
        self.search = search
        self.filter = filter
        self.sort = sort
    }

    public var isSearching: Bool { !terms.isEmpty }

    var terms: [String] {
        search.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    public func apply(to items: [LibraryItem]) -> [LibraryItem] {
        let terms = self.terms
        let kept = items.filter { item in
            guard filter.includes(item) else { return false }
            guard !terms.isEmpty else { return true }
            let haystack = Self.fold([item.title, item.purposeTitle ?? "", item.transcriptText ?? ""]
                .joined(separator: " "))
            return terms.allSatisfy { haystack.contains($0) }
        }
        return sorted(kept)
    }

    /// Ties keep the folder order, newest first.
    private func sorted(_ items: [LibraryItem]) -> [LibraryItem] {
        let indexed = Array(items.enumerated())
        func newer(_ a: LibraryItem, _ b: LibraryItem) -> Bool? {
            switch (a.recordedAt, b.recordedAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return nil
            }
        }
        return indexed.sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let decided: Bool?
            switch sort {
            case .newest:
                decided = newer(a, b)
            case .oldest:
                decided = newer(a, b).map { !$0 }
            case .longest:
                let x = a.duration ?? -1, y = b.duration ?? -1
                decided = x == y ? nil : x > y
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                decided = order == .orderedSame ? nil : order == .orderedAscending
            }
            return decided ?? (lhs.offset < rhs.offset)
        }.map(\.element)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

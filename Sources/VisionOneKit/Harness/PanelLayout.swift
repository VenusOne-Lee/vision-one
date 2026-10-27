import Foundation

/// A component that can sit in the right-hand panel beside a task.
public enum PanelKind: String, Codable, CaseIterable, Sendable {
    case video, changes, clips, sound, post, captions, thumbnail, formats

    public var title: String {
        switch self {
        case .video: return "Video"
        case .changes: return "Changes"
        case .clips: return "Clips"
        case .sound: return "Sound"
        case .post: return "Post"
        case .captions: return "Captions"
        case .thumbnail: return "Thumbnail"
        case .formats: return "Formats"
        }
    }

    public var symbol: String {
        switch self {
        case .video: return "play.rectangle"
        case .changes: return "scissors"
        case .clips: return "rectangle.stack"
        case .sound: return "waveform"
        case .post: return "paperplane"
        case .captions: return "captions.bubble"
        case .thumbnail: return "photo"
        case .formats: return "aspectratio"
        }
    }
}

/// Which components the right panel shows for one task: open tabs, the one
/// in front, an optional second one split below it, and the panel's width.
public struct PanelLayout: Codable, Equatable, Sendable {
    public static let standard = PanelLayout(tabs: [.video, .changes, .clips, .post], selected: .video)
    public static let minWidth: Double = 280
    public static let maxWidth: Double = 720

    public private(set) var tabs: [PanelKind]
    public private(set) var selected: PanelKind?
    /// Shown under the selected tab when the panel is split.
    public private(set) var split: PanelKind?
    public var isHidden: Bool
    public private(set) var width: Double
    /// Top share of the height when split, 0.2...0.8.
    public private(set) var splitFraction: Double

    public init(tabs: [PanelKind], selected: PanelKind? = nil, split: PanelKind? = nil,
                isHidden: Bool = false, width: Double = 380, splitFraction: Double = 0.5) {
        var unique: [PanelKind] = []
        for tab in tabs where !unique.contains(tab) { unique.append(tab) }
        let front = selected.flatMap { unique.contains($0) ? $0 : nil } ?? unique.first
        self.tabs = unique
        self.selected = front
        self.split = split.flatMap { unique.contains($0) && $0 != front ? $0 : nil }
        self.isHidden = isHidden
        self.width = min(Self.maxWidth, max(Self.minWidth, width))
        self.splitFraction = min(0.8, max(0.2, splitFraction))
    }

    /// Components not open yet, for the + menu.
    public var addable: [PanelKind] { PanelKind.allCases.filter { !tabs.contains($0) } }

    /// Opens it (at the end) and brings it to the front.
    public mutating func show(_ kind: PanelKind) {
        if !tabs.contains(kind) { tabs.append(kind) }
        if split == kind { split = selected }
        selected = kind
        isHidden = false
    }

    public mutating func close(_ kind: PanelKind) {
        guard let i = tabs.firstIndex(of: kind) else { return }
        tabs.remove(at: i)
        if split == kind { split = nil }
        if selected == kind {
            selected = split ?? (tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)])
            if split == selected { split = nil }
        }
    }

    /// Drag a tab to a new place.
    public mutating func move(_ kind: PanelKind, to index: Int) {
        guard let from = tabs.firstIndex(of: kind) else { return }
        tabs.remove(at: from)
        tabs.insert(kind, at: min(max(0, index), tabs.count))
    }

    /// ◫: splits with the next open tab, or closes the split.
    public mutating func toggleSplit() {
        if split != nil {
            split = nil
        } else if let selected, let other = tabs.first(where: { $0 != selected }) {
            split = other
        }
    }

    /// Puts a specific component in the bottom half.
    public mutating func splitWith(_ kind: PanelKind) {
        if !tabs.contains(kind) { tabs.append(kind) }
        if kind == selected {
            guard let other = split ?? tabs.first(where: { $0 != kind }) else { return }
            selected = other
        }
        split = kind
    }

    public mutating func setWidth(_ value: Double) {
        width = min(Self.maxWidth, max(Self.minWidth, value))
    }

    public mutating func setSplitFraction(_ value: Double) {
        splitFraction = min(0.8, max(0.2, value))
    }
}

/// Panel layouts kept per task (by take folder name), with the last one
/// used as the start for a new task.
public struct PanelLayoutBook: Codable, Equatable, Sendable {
    public var byTask: [String: PanelLayout]
    public var last: PanelLayout

    public init(byTask: [String: PanelLayout] = [:], last: PanelLayout = .standard) {
        self.byTask = byTask
        self.last = last
    }

    public func layout(for task: String) -> PanelLayout { byTask[task] ?? last }

    public mutating func set(_ layout: PanelLayout, for task: String) {
        byTask[task] = layout
        last = layout
    }

    public static func decode(_ data: Data?) -> PanelLayoutBook {
        data.flatMap { try? JSONDecoder().decode(PanelLayoutBook.self, from: $0) } ?? PanelLayoutBook()
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

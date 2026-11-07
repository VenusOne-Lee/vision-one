import Foundation

/// Marks drawn on the screen while recording (the pen on the REC bar),
/// saved with the take as drawings.json and drawn into the editor preview
/// and every export. Vision One's own windows are never in screen.mov, so
/// this file is the only record of them.
///
/// Times are seconds from screen.mov's first frame. Points are a share of
/// the recorded width and height, from the top left.
public struct ScreenDrawing: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    public struct Stroke: Codable, Equatable, Sendable {
        public var points: [Point]

        public init(points: [Point]) {
            self.points = points
        }

        public var start: Double { points.first?.t ?? 0 }
        public var end: Double { points.last?.t ?? 0 }
    }

    /// A stroke as it shows at one moment: the part drawn so far, and how
    /// strongly (1 solid, 0 gone).
    public struct Visible: Equatable, Sendable {
        public var points: [Point]
        public var opacity: Double

        public init(points: [Point], opacity: Double) {
            self.points = points
            self.opacity = opacity
        }
    }

    public var version: Int
    public var strokes: [Stroke]

    /// How long a finished stroke stays up, then how long it fades.
    public static let holdSeconds = 3.0
    public static let fadeSeconds = 0.5

    public init(strokes: [Stroke]) {
        version = 1
        self.strokes = strokes.filter { !$0.points.isEmpty }.sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { strokes.isEmpty }

    /// What shows `t` seconds into the recording. A stroke draws on as it
    /// was drawn, holds, then fades.
    public func visible(atSource t: Double) -> [Visible] {
        strokes.compactMap { stroke in
            guard t >= stroke.start else { return nil }
            let age = t - stroke.end - Self.holdSeconds
            let opacity = age <= 0 ? 1 : 1 - age / Self.fadeSeconds
            guard opacity > 0 else { return nil }
            let drawn = t >= stroke.end ? stroke.points : stroke.points.filter { $0.t <= t }
            return drawn.isEmpty ? nil : Visible(points: drawn, opacity: opacity)
        }
    }

    // MARK: File

    public static func read(from url: URL) -> ScreenDrawing? {
        guard let data = try? Data(contentsOf: url),
              let drawing = try? JSONDecoder().decode(ScreenDrawing.self, from: data),
              !drawing.isEmpty else { return nil }
        return drawing
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

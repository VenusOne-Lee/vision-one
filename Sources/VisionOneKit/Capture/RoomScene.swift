import Foundation

/// The rooms Vision One draws itself, so there are no photos to license
/// and every room comes already split into depth layers for "Move with me".
public enum RoomID: String, Codable, CaseIterable, Sendable {
    case loft, studio, gallery

    public var title: String { rawValue.capitalized }

    public var scene: RoomScene {
        switch self {
        case .loft: return .loft
        case .studio: return .studio
        case .gallery: return .gallery
        }
    }
}

/// Where a room's main light comes from, seen from the camera. The
/// person's shadow falls the other way.
public enum LightSide: String, Codable, Sendable {
    case left, right, front
}

/// A room as flat layers, far to near, each made of simple shapes in
/// shares of the frame (top left origin). The app draws them with Core
/// Graphics at whatever size the camera frame is.
public struct RoomScene: Equatable, Sendable {
    public let id: RoomID
    public let lightFrom: LightSide
    /// Where the desk or floor meets the person, as a share from the top.
    public let deskLine: Double
    public let layers: [Layer]

    public struct Layer: Equatable, Sendable {
        /// 0 is far away (barely moves, most blur), 1 is right behind the
        /// person (moves most, sharpest).
        public let depth: Double
        public let shapes: [Shape]
    }

    public struct Shape: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case rect
            /// Corner radius as a share of the shape's shorter side.
            case rounded(Double)
            case ellipse
            /// Top colour to `colour2` at the bottom.
            case gradient
            /// Soft light: `colour` in the middle fading to clear at the edge.
            case glow
            /// An outline; line width as a share of the frame's width.
            case frame(Double)
        }

        public let kind: Kind
        public let rect: NormalisedRect
        /// 0xRRGGBB
        public let colour: UInt32
        public let colour2: UInt32?
        public let opacity: Double

        public init(_ kind: Kind, _ rect: NormalisedRect, _ colour: UInt32, _ colour2: UInt32? = nil, opacity: Double = 1) {
            self.kind = kind
            self.rect = rect
            self.colour = colour
            self.colour2 = colour2
            self.opacity = opacity
        }
    }

    private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalisedRect {
        NormalisedRect(x: x, y: y, width: w, height: h)
    }

    /// Warm plaster, a window on the left, a lamp, a bookshelf and a desk.
    public static let loft = RoomScene(id: .loft, lightFrom: .left, deskLine: 0.82, layers: [
        Layer(depth: 0.15, shapes: [
            Shape(.gradient, r(0, 0, 1, 1), 0xEDE6DA, 0xD6CBB9),
            Shape(.glow, r(-0.05, -0.05, 0.6, 0.9), 0xFFF4DC, opacity: 0.7),
            Shape(.rect, r(0.08, 0.10, 0.24, 0.44), 0xF7F3EA),
            Shape(.glow, r(0.04, 0.04, 0.32, 0.56), 0xFFFBEF, opacity: 0.9),
            Shape(.frame(0.008), r(0.08, 0.10, 0.24, 0.44), 0xE2D8C6),
            Shape(.rect, r(0.198, 0.10, 0.004, 0.44), 0xE2D8C6),
            Shape(.rect, r(0.08, 0.318, 0.24, 0.004), 0xE2D8C6),
            Shape(.rect, r(0.64, 0.14, 0.15, 0.20), 0xD9C7AC),
            Shape(.frame(0.005), r(0.64, 0.14, 0.15, 0.20), 0x121212),
            Shape(.gradient, r(0, 0.66, 1, 0.34), 0xBBA98F, 0xA69479),
        ]),
        Layer(depth: 0.5, shapes: [
            Shape(.glow, r(0.0, 0.22, 0.2, 0.3), 0xF2D9A0, opacity: 0.8),
            Shape(.rounded(0.3), r(0.05, 0.28, 0.1, 0.08), 0xF2D9A0),
            Shape(.rect, r(0.093, 0.36, 0.014, 0.34), 0x6B5A48),
            Shape(.rounded(0.05), r(0.74, 0.40, 0.22, 0.42), 0x9C7A57),
            Shape(.rect, r(0.755, 0.53, 0.19, 0.012), 0x7E6045),
            Shape(.rect, r(0.755, 0.67, 0.19, 0.012), 0x7E6045),
            Shape(.rect, r(0.77, 0.45, 0.022, 0.08), 0xC9B79C),
            Shape(.rect, r(0.795, 0.465, 0.02, 0.065), 0xE6DED0),
            Shape(.rect, r(0.818, 0.445, 0.024, 0.085), 0x5E6672),
            Shape(.rect, r(0.86, 0.59, 0.05, 0.08), 0xC2306E, opacity: 0.5),
        ]),
        Layer(depth: 1.0, shapes: [
            Shape(.gradient, r(-0.05, 0.82, 1.1, 0.2), 0x8A6A4B, 0x6F543A),
            Shape(.rect, r(-0.05, 0.82, 1.1, 0.006), 0xA88660),
        ]),
    ])

    /// A seamless photo backdrop: soft grey sweep, lit from the front.
    public static let studio = RoomScene(id: .studio, lightFrom: .front, deskLine: 0.86, layers: [
        Layer(depth: 0.15, shapes: [
            Shape(.gradient, r(0, 0, 1, 1), 0xE9E8E4, 0xC9C7C1),
            Shape(.glow, r(0.15, 0.0, 0.7, 0.85), 0xFFFFFF, opacity: 0.95),
        ]),
        Layer(depth: 0.6, shapes: [
            Shape(.gradient, r(-0.05, 0.72, 1.1, 0.3), 0xDAD8D2, 0xBDBAB2, opacity: 0.85),
        ]),
        Layer(depth: 1.0, shapes: [
            Shape(.gradient, r(-0.05, 0.86, 1.1, 0.16), 0x2B2B2B, 0x121212),
        ]),
    ])

    /// A white gallery wall with two prints and a bench, lit from the right.
    public static let gallery = RoomScene(id: .gallery, lightFrom: .right, deskLine: 0.84, layers: [
        Layer(depth: 0.15, shapes: [
            Shape(.gradient, r(0, 0, 1, 1), 0xFBFBF9, 0xE6E5E0),
            Shape(.glow, r(0.5, -0.1, 0.6, 0.8), 0xFFFFFF, opacity: 0.9),
            Shape(.rect, r(0.10, 0.16, 0.18, 0.26), 0xFFFFFF),
            Shape(.rect, r(0.12, 0.19, 0.14, 0.20), 0x1F3FBF, opacity: 0.85),
            Shape(.frame(0.004), r(0.10, 0.16, 0.18, 0.26), 0x121212),
            Shape(.rect, r(0.72, 0.12, 0.16, 0.32), 0xFFFFFF),
            Shape(.ellipse, r(0.75, 0.2, 0.1, 0.12), 0xE0A21B, opacity: 0.9),
            Shape(.frame(0.004), r(0.72, 0.12, 0.16, 0.32), 0x121212),
            Shape(.gradient, r(0, 0.7, 1, 0.3), 0xD8D3C8, 0xC4BEB1),
        ]),
        Layer(depth: 0.55, shapes: [
            Shape(.rounded(0.1), r(0.06, 0.62, 0.3, 0.05), 0xB79A74),
            Shape(.rect, r(0.08, 0.67, 0.02, 0.12), 0x7E6045),
            Shape(.rect, r(0.32, 0.67, 0.02, 0.12), 0x7E6045),
        ]),
        Layer(depth: 1.0, shapes: [
            Shape(.gradient, r(-0.05, 0.84, 1.1, 0.18), 0xEDEBE6, 0xD4D1C9),
            Shape(.rect, r(-0.05, 0.84, 1.1, 0.005), 0xC9C8C3),
        ]),
    ])
}

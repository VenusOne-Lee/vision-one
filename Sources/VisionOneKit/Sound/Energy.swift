import Foundation

/// The Energy dial: one control for how busy the edit feels. Sound
/// effects read it now; zooms and caption style will read it too.
/// Templates set the starting value.
public enum Energy: String, Codable, CaseIterable, Sendable {
    case calm, lively, viral

    public var title: String {
        switch self {
        case .calm: return "Calm"
        case .lively: return "Lively"
        case .viral: return "Viral"
        }
    }
}

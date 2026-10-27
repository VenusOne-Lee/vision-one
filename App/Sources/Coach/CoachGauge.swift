import SwiftUI
import VisionOneKit

/// One meter: a bar with the target band drawn dashed (proposed: where
/// you're aiming) and the reading as a solid ink tick. Ink only; never
/// orange, which means recording is live, and never green.
struct CoachGauge: View {
    let label: String
    let value: String
    var unit: String = ""
    /// 0...1 along the bar, nil while there's nothing to show.
    let position: Double?
    /// 0...1 start and end of the target band.
    let band: ClosedRange<Double>
    var zone: MeterZone = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label.uppercased()).textStyle(.label).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 4)
                Text(value).textStyle(.mono).monospacedDigit().foregroundStyle(Theme.text)
                if !unit.isEmpty { Text(unit).textStyle(.caption).foregroundStyle(Theme.textMuted) }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.canvas)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: Theme.Stroke.dashSmall))
                        .frame(width: max(4, w * (band.upperBound - band.lowerBound)))
                        .offset(x: w * band.lowerBound)
                    if let position {
                        Capsule()
                            .fill(Theme.text)
                            .frame(width: 3, height: 14)
                            .offset(x: max(0, min(w - 3, w * position - 1.5)))
                            .animation(Theme.Motion.reduced ? nil : .easeOut(duration: 0.25), value: position)
                    }
                }
            }
            .frame(height: 14)
            Text(hint).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
        .padding(Theme.Space.sm + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit), \(hint)")
    }

    private var hint: String {
        switch zone {
        case .low: return "Below your target"
        case .high: return "Above your target"
        case .inBand: return "On target"
        case .unknown: return "Waiting for you"
        }
    }
}

/// Plays a short clip of a practice run from a time, for the coach's notes.
struct PlayMomentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
        .help("Play this moment back")
        .accessibilityLabel("Play this moment back")
    }
}

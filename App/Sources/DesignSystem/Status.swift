import SwiftUI

// MARK: Dashed, solid, orange

/// The app's one grammar: dashed = proposed or not done yet, solid =
/// accepted or done, orange = recording is live. Applies to rings, AI
/// changes, format shapes and takes.
enum StatusMark: Equatable {
    case proposed, accepted, live

    var color: Color {
        switch self {
        case .proposed, .accepted: Theme.text
        case .live: Theme.tally
        }
    }

    var dash: [CGFloat] { self == .proposed ? Theme.Stroke.dash : [] }

    var spoken: String {
        switch self {
        case .proposed: "Suggested"
        case .accepted: "Accepted"
        case .live: "Live"
        }
    }
}

extension View {
    /// Outlines a view in the grammar's stroke.
    func statusOutline(_ mark: StatusMark, cornerRadius: CGFloat = Theme.Radius.md,
                       lineWidth: CGFloat = Theme.Stroke.ring) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(mark.color, style: StrokeStyle(lineWidth: lineWidth, dash: mark.dash))
        )
    }
}

/// A small pill that says a state in words and in its stroke.
/// `StatusChip`-style: `StateChip(.proposed, "Suggested")`.
struct StateChip: View {
    let mark: StatusMark
    let text: String

    init(_ mark: StatusMark, _ text: String) {
        self.mark = mark
        self.text = text
    }

    var body: some View {
        Text(text)
            .textStyle(.caption)
            .fontWeight(.medium)
            .foregroundStyle(mark == .proposed ? Theme.textMuted : Theme.text)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(mark.color,
                                            style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: mark == .proposed ? [3, 2] : [])))
            .accessibilityLabel(text)
    }
}

// MARK: Tag

/// A neutral label: canvas fill, muted text. Never orange, never green.
struct Tag: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.caption)
            .fontWeight(.medium)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.canvas))
    }
}

// MARK: Notice

/// Tint plus a bold lead sentence. Errors say how to fix it, for example
/// the System Settings path for Screen Recording.
struct Notice: View {
    enum Kind { case info, error }

    let kind: Kind
    let lead: String
    var detail: String?
    var action: (title: String, run: () -> Void)?

    init(_ kind: Kind, lead: String, detail: String? = nil, action: (title: String, run: () -> Void)? = nil) {
        self.kind = kind
        self.lead = lead
        self.detail = detail
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: kind == .error ? "exclamationmark.circle.fill" : "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind == .error ? Theme.error : Theme.textMuted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(lead).textStyle(.headline).foregroundStyle(kind == .error ? Theme.error : Theme.text)
                if let detail {
                    Text(detail)
                        .textStyle(.body)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(kind == .error ? Theme.errorSoft : Theme.canvas))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind == .error ? "Problem: \(lead)" : lead)
    }
}

// MARK: Numbers

/// Timecodes, sizes and durations in JetBrains Mono, so digits never jump.
struct Mono: View {
    let text: String
    var small = false

    init(_ text: String, small: Bool = false) {
        self.text = text
        self.small = small
    }

    var body: some View {
        Text(text).textStyle(small ? .monoSmall : .mono).monospacedDigit()
    }
}

// MARK: Live

/// The REC dot. The only orange in the app, shown only while recording.
/// Blinks gently; holds still with Reduce Motion on.
struct LiveDot: View {
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.tally)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel("Recording")
    }
}

/// The builder's ring, the status light for a take: dashed = draft,
/// dashed and slowly turning with an orange centre = recording, an arc
/// filling = exporting, solid = exported. Colour is the builder's ring
/// colour (identity), ink until it's set.
struct BuilderRing: View {
    enum State: Equatable {
        case draft
        case recording
        case exporting(Double)
        case exported
    }

    let state: State
    var colour: Color = Theme.text
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var turn = false

    private var lineWidth: CGFloat { max(1.5, size / 10) }

    var body: some View {
        ZStack {
            switch state {
            case .draft:
                Circle().strokeBorder(colour, style: StrokeStyle(lineWidth: lineWidth, dash: Theme.Stroke.dashSmall))
            case .recording:
                Circle()
                    .strokeBorder(colour, style: StrokeStyle(lineWidth: lineWidth, dash: Theme.Stroke.dashSmall))
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { turn = true }
                    }
                Circle().fill(Theme.tally).frame(width: size * 0.38, height: size * 0.38)
            case .exporting(let progress):
                Circle().strokeBorder(colour.opacity(0.45), style: StrokeStyle(lineWidth: lineWidth, dash: Theme.Stroke.dashSmall))
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(colour, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .motion(.easeOut(duration: Theme.Motion.medium), value: progress)
            case .exported:
                Circle().strokeBorder(colour, lineWidth: lineWidth)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        switch state {
        case .draft: "Not exported yet"
        case .recording: "Recording"
        case .exporting(let p): "Exporting, \(Int((p * 100).rounded())) percent"
        case .exported: "Exported"
        }
    }
}

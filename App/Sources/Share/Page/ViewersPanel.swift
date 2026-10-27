import SwiftUI
import VisionOneKit

/// What came back from the share page: views, the still-watching curve,
/// the coach's note on where people stop, and viewers' notes. Notes are
/// also filed as asks on the take's Desk task when they arrive.
struct ViewersPanel: View {
    @ObservedObject var model: SharePageModel

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("VIEWERS")
                    .textStyle(.caption)
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                Button("Check now") { Task { await model.pull() } }
                    .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
            }
            .padding(.top, Theme.Space.xs)

            if summary.views == 0 && model.inbox.notes.isEmpty {
                Text("Nobody has watched yet. Views, questions and notes show here.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Theme.Space.sm) {
                    Stat(value: "\(summary.views)", label: "views")
                    Stat(value: Timecode.short(from: summary.averageWatched), label: "average watched")
                    Stat(value: "\(summary.questions.count)", label: "questions")
                }
                if model.curve.views > 0 {
                    CurveView(curve: model.curve, drop: model.coachHint?.drop)
                        .frame(height: 70)
                        .accessibilityLabel("Still watching over time")
                }
                if let hint = model.coachHint { CoachCard(hint: hint) { model.askEditor(hint.ask) } }
                if !summary.reactions.isEmpty {
                    Text(summary.reactions.prefix(5).map { "\($0.emoji) \($0.count)" }.joined(separator: "   "))
                        .textStyle(.body)
                }
                if !summary.questions.isEmpty {
                    DisclosureGroup("People asked (\(summary.questions.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.questions.suffix(20).reversed().enumerated()), id: \.offset) { _, q in
                                Text("“\(q)”").textStyle(.body).foregroundStyle(Theme.text)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .textStyle(.caption)
                }
                ForEach(model.inbox.openNotes) { note in
                    NoteCard(note: note, fix: { model.askEditor(note.editorAsk) }, done: { model.markDone(note) })
                }
            }
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Mono(value)
            Text(label).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// Share still watching from the start to the end, with the biggest
/// drop shaded.
private struct CurveView: View {
    let curve: WatchCurve
    let drop: DropOff?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(1, curve.stillWatching.count - 1)
            let point = { (i: Int) -> CGPoint in
                CGPoint(x: w * CGFloat(i) / CGFloat(n), y: h * (1 - CGFloat(curve.stillWatching[i])))
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper)
                if let drop, curve.duration > 0 {
                    Rectangle()
                        .fill(Color(hex: DesignTokens.selectionSoft))
                        .frame(width: max(2, w * CGFloat((drop.to - drop.from) / curve.duration)))
                        .offset(x: w * CGFloat(drop.from / curve.duration))
                }
                Path { path in
                    guard !curve.stillWatching.isEmpty else { return }
                    path.move(to: point(0))
                    for i in 1..<curve.stillWatching.count { path.addLine(to: point(i)) }
                }
                .stroke(Theme.text, lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }
}

/// The coach's suggestion, dashed until you act on it.
private struct CoachCard: View {
    let hint: ViewerCoachHint
    let ask: () -> Void
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COACH · FROM VIEWERS").textStyle(.caption).tracking(0.6).foregroundStyle(Theme.textMuted)
            Text(hint.headline).textStyle(.headline).foregroundStyle(Theme.text)
            Text(hint.detail).textStyle(.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Button(asked ? "Asked the Editor" : (hint.kind == .hook ? "Propose a tighter opening" : "Propose cuts here")) {
                ask()
                asked = true
            }
            .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
            .disabled(asked)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .statusOutline(asked ? .accepted : .proposed, cornerRadius: Theme.Radius.lg)
    }
}

private struct NoteCard: View {
    let note: ViewerNote
    let fix: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(note.who.uppercased()) · ").textStyle(.caption).tracking(0.6).foregroundStyle(Theme.textMuted)
                Mono(Timecode.short(from: note.at), small: true).foregroundStyle(Theme.textMuted)
            }
            Text(note.text).textStyle(.bodyStrong).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            if let quote = note.quote {
                Text("“\(quote)”").textStyle(.transcript).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                Button("Ask the Editor to fix", action: fix).buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                Button("Mark done", action: done).buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .statusOutline(.proposed, cornerRadius: Theme.Radius.lg)
    }
}

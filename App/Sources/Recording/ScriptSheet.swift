import SwiftUI
import VisionOneKit

/// Write or paste the script for the next take. Each sentence becomes a
/// line on the teleprompter.
struct ScriptSheet: View {
    @ObservedObject var store: ScriptStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Script").textStyle(.title)
            Text("Paste or write what you'll say. The teleprompter follows your voice, and if you fluff a line, just say it again: Vision One keeps your best try.")
                .textStyle(.body)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $store.text)
                .font(TypeStyle.transcript.font())
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))
                .frame(minHeight: 220)
                .accessibilityLabel("Script")
            HStack(spacing: Theme.Space.sm) {
                Mono(summary, small: true)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Toggle("Show the teleprompter", isOn: $store.showsPrompter)
                    .toggleStyle(.ink)
            }
            HStack(spacing: Theme.Space.sm) {
                Button("Clear") { store.clear() }
                    .buttonStyle(.quiet)
                    .disabled(store.text.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.canvas)
    }

    private var summary: String {
        let script = Script(text: store.text)
        guard !script.isEmpty else { return "No script: the take records without a teleprompter" }
        let seconds = Int(script.estimatedSeconds().rounded())
        return "\(script.lines.count) lines · \(script.wordCount) words · about \(seconds / 60):\(String(format: "%02d", seconds % 60)) at a calm pace"
    }
}

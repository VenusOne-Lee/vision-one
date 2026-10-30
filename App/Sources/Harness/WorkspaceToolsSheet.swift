import SwiftUI
import VisionOneKit

/// Contextual preparation and advanced work keep the current task open.
struct WorkspaceToolsSheet: View {
    @ObservedObject var model: HarnessModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task tools").textStyle(.title)
                    Text(model.task?.title ?? "Prepare your next video")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                IconButton("Close task tools", systemImage: "xmark", action: close)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .top)], spacing: 12) {
                    tool("Script Coach", icon: "doc.text", detail: "Check length and pacing on this Mac. Rewrites use the AI provider selected in Settings.", action: "Open Script Coach") {
                        ScriptCoachWindowController.shared.show()
                    }
                    tool("Rehearse", icon: "mic", detail: "Practice without saving a take. Live feedback needs microphone and Speech Recognition access.", action: "Open rehearsal") {
                        RehearseWindowController.shared.show()
                    }
                    tool("Voice tools", icon: "waveform", detail: "Optional ElevenLabs cleanup and word fixes. Requires a take and an API key; audio sends ask first.", action: "Open voice tools", needsTake: true) {
                        VoiceToolsWindowController.shared.show(for: model.workspace?.take)
                    }
                    tool("Autopilot demos", icon: "sparkles", detail: "Build and review a repeatable demo. Running one needs Accessibility and Screen Recording access.", action: "Open Autopilot") {
                        AutopilotWindowController.shared.show()
                    }
                    tool("Agent recording and MCP", icon: "terminal", detail: "Connect coding agents locally. Review permissions in Settings; recording, keeping changes and sharing retain approval gates.", action: "Open agent settings") {
                        SettingsWindowController.shared.show(.agents)
                    }
                    tool("Languages and versions", icon: "character.bubble", detail: "Translate captions or prepare dubs for this take. Dubbing requires an optional voice provider and approval.", action: "Open languages", needsTake: true) {
                        if let take = model.workspace?.take { LanguagesWindowController.shared.show(for: take) }
                    }
                }
            }
            Text("Your task stays open when a tool opens in its own window.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
        }
        .padding(24).frame(minWidth: 600, idealWidth: 680, maxWidth: 800)
        .frame(height: 580).background(Theme.canvas).foregroundStyle(Theme.text).themed()
    }

    private func tool(_ title: String, icon: String, detail: String, action: String,
                      needsTake: Bool = false, open: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).textStyle(.bodyStrong)
            Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action) { close(); open() }.buttonStyle(.secondary)
                .disabled(needsTake && model.workspace == nil)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading).panelStyle()
    }
}

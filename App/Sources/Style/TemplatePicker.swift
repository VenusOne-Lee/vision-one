import SwiftUI
import VisionOneKit

struct TemplatePicker: View {
    @Binding var selection: String
    @State private var userLooks = UserTemplates.loadAll().map(\.look)
    var body: some View {
        Picker("Reusable style", selection: $selection) {
            Text("No template").tag("")
            ForEach(TemplateLook.builtIn) { Text($0.title).tag($0.id) }
            if !userLooks.isEmpty {
                Divider()
                ForEach(userLooks) { Text($0.title).tag($0.id) }
            }
            if !selection.isEmpty, !TemplateLook.builtIn.contains(where: { $0.id == selection }),
               !userLooks.contains(where: { $0.id == selection }) {
                Text("Unavailable template (choose another)").tag(selection)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userTemplatesChanged)) { _ in
            userLooks = UserTemplates.loadAll().map(\.look)
        }
    }
}

/// Explicit restyling is available from the task's contextual tools. New
/// recordings and imports receive project defaults automatically instead.
struct ApplyTemplateSheet: View {
    @ObservedObject var workspace: TaskWorkspace
    let close: () -> Void
    @State private var selection = ""
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Apply a reusable style").textStyle(.title)
            TemplatePicker(selection: $selection)
            Text("Applies caption style, Energy, cleanup rhythm and output defaults. Intro, outro and watermark choices follow the template. Existing cuts, manual framing, caption size, position and language are kept.")
                .textStyle(.body).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Text("Copied music traits never copy copyrighted audio. Choose a music track in Sound. Copied zoom frequency limits new click-zoom suggestions. Copied card colours apply when the brand has no custom paper/ink override.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).textStyle(.caption).foregroundStyle(Theme.error) }
            HStack {
                Button("Copy a style…") { CopyStyleWindowController.shared.show() }.buttonStyle(.quiet)
                Spacer()
                Button("Cancel", action: close).buttonStyle(.secondary)
                Button("Apply") { apply() }.buttonStyle(.primary).disabled(selection.isEmpty)
            }
        }
        .padding(Theme.Space.lg).frame(width: 520).background(Theme.canvas).foregroundStyle(Theme.text).themed()
        .onAppear { selection = AppliedTemplate.look(for: workspace.take)?.id ?? "" }
    }
    private func apply() {
        do {
            try AppliedTemplate.apply(id: selection, to: workspace.take, overwrite: true)
            let energy = TakePlan.load(for: workspace.take)?.energy ?? .calm
            workspace.editor.setEnergy(energy)
            workspace.editor.effects.findZooms(energy: ZoomEnergy(rawValue: energy.rawValue) ?? .calm,
                                                edits: workspace.editor.edits)
            NotificationCenter.default.post(name: .takeStyleChanged, object: workspace.take.folder)
            close()
        } catch { problem = "Couldn't apply this template: \(error.localizedDescription)" }
    }
}

extension Notification.Name {
    static let takeStyleChanged = Notification.Name("VisionOneTakeStyleChanged")
}

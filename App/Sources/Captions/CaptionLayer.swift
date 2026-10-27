import SwiftUI
import VisionOneKit

/// Captions over the editor's player. Rebuilds the cues whenever the
/// transcript, the cuts or the caption settings change, saves settings to
/// the take's captions.json, and offers the caption controls from a
/// "Captions" pill in the corner.
struct CaptionLayer: View {
    @ObservedObject var model: EditorModel

    @State private var settings = CaptionSettings()
    @State private var track = CaptionTrack(cues: [])
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if settings.isOn {
                CaptionPreview(
                    track: track,
                    settings: $settings,
                    time: model.edits.outputTime(forSource: model.sourceTime) ?? -1
                )
            }
            Button("Captions") { showControls.toggle() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .padding(Theme.Space.sm)
                .popover(isPresented: $showControls, arrowEdge: .bottom) {
                    CaptionControls(settings: $settings)
                        .padding(Theme.Space.md)
                        .frame(width: 300)
                        .background(Theme.paper)
                        .environment(\.colorScheme, .light)
                }
                .help("Caption style, size and files")
        }
        .task(id: model.take.folder) {
            settings = model.take.loadCaptionSettings()
            rebuild()
        }
        .onChange(of: model.transcript) { _, _ in rebuild() }
        .onChange(of: model.edits) { _, _ in rebuild() }
        .onChange(of: settings) { _, newValue in
            rebuild()
            try? model.take.saveCaptionSettings(newValue)
        }
    }

    private func rebuild() {
        guard let transcript = model.transcript else {
            track = CaptionTrack(cues: [])
            return
        }
        track = CaptionTrack(cues: settings.builder.cues(for: transcript, edits: model.edits))
    }
}

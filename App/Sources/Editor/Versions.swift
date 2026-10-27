import AVFoundation
import SwiftUI
import VisionOneKit

/// "Try in a copy" for one take: make a copy to try a big change, switch
/// between versions, pick the main cut, and compare two side by side.
@MainActor
final class VersionsModel: ObservableObject {
    @Published private(set) var index: TakeVersions.Index
    @Published var error: String?

    let versions: TakeVersions
    private weak var editor: EditorModel?

    init(editor: EditorModel) {
        self.editor = editor
        versions = TakeVersions(take: editor.take)
        index = versions.index()
    }

    var open: TakeVersion? { index.versions.first { $0.id == index.open } }
    var main: TakeVersion? { index.versions.first { $0.id == index.main } }
    var hasCopies: Bool { index.versions.count > 1 }

    func name(_ id: String) -> String { index.versions.first { $0.id == id }?.name ?? id }

    /// Parks what's open and opens a copy of it to change freely.
    func tryCopy(named name: String? = nil, note: String? = nil) {
        perform { _ = try versions.tryCopy(named: name ?? versions.nextCopyName(), note: note) }
    }

    func open(_ id: String) { perform { try versions.open(id) } }
    func makeMain(_ id: String) { perform { try versions.makeMain(id) } }
    func delete(_ id: String) { perform { try versions.delete(id) } }

    private func perform(_ change: () throws -> Void) {
        let before = index.open
        do {
            try change()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        index = versions.index()
        // Another version's files are in the take's folder now.
        if index.open != before { editor?.reloadFiles() }
    }
}

// MARK: The menu

/// "Main cut ▾" beside the transport: the version you're editing, the
/// others, Try in a copy and Compare.
struct VersionMenu: View {
    @ObservedObject var model: VersionsModel
    let compare: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            menu
            if let error = model.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.error)
                    .lineLimit(1)
                    .help(error)
            }
        }
    }

    private var menu: some View {
        Menu {
            Section("Versions") {
                ForEach(model.index.versions) { version in
                    Button {
                        model.open(version.id)
                    } label: {
                        if version.id == model.index.open {
                            Label(title(version), systemImage: "checkmark")
                        } else {
                            Text(title(version))
                        }
                    }
                    .disabled(version.locked)
                }
            }
            Divider()
            Button("Try in a copy") { model.tryCopy() }
            Button("Compare versions…", action: compare)
                .disabled(!model.hasCopies)
            if let open = model.open, open.id != model.index.main {
                Button("Make \(open.name) the main cut") { model.makeMain(open.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.open?.name ?? "Main cut").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: Theme.Size.controlSmall + 2)
            .overlay(Capsule().strokeBorder(Theme.text, style: StrokeStyle(
                lineWidth: 1, dash: model.index.open == model.index.main ? [] : Theme.Stroke.dash)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.index.open == model.index.main
              ? "The main cut. Try a big change in a copy and this stays safe."
              : "A copy, dashed until you make it the main cut")
    }

    private func title(_ version: TakeVersion) -> String {
        var parts = [version.name]
        if version.id == model.index.main { parts.append("main") }
        if version.locked { parts.append("exported, locked") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Compare

/// Two versions side by side. Play both together, then make one the
/// main cut or keep both.
struct CompareView: View {
    @ObservedObject var versions: VersionsModel
    let take: Take
    let done: () -> Void

    @State private var leftID: String
    @State private var rightID: String
    @StateObject private var left = VersionPreview()
    @StateObject private var right = VersionPreview()

    init(versions: VersionsModel, take: Take, done: @escaping () -> Void) {
        self.versions = versions
        self.take = take
        self.done = done
        let index = versions.index
        let main = index.main
        let other = index.open != main ? index.open : (index.versions.last { $0.id != main }?.id ?? main)
        _leftID = State(initialValue: main)
        _rightID = State(initialValue: other)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("Compare").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(left.isPlaying || right.isPlaying ? "Pause both" : "Play both") { playBoth() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            HStack(alignment: .top, spacing: Theme.Space.md) {
                side(id: $leftID, preview: left)
                side(id: $rightID, preview: right)
            }
            HStack(spacing: Theme.Space.sm) {
                if rightID != versions.index.main {
                    Button("Make \(versions.name(rightID)) the main cut") {
                        versions.makeMain(rightID)
                        done()
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button("Keep both", action: done)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Text("The main cut is what Home and Library show. Exported versions stay locked.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Space.lg)
        .frame(minWidth: 820, minHeight: 460)
        .background(Theme.paper)
        .task(id: leftID) { await left.load(take: take, folder: versions.versions.folder(for: leftID, in: versions.index)) }
        .task(id: rightID) { await right.load(take: take, folder: versions.versions.folder(for: rightID, in: versions.index)) }
        .onDisappear {
            left.player.pause()
            right.player.pause()
        }
    }

    private func side(id: Binding<String>, preview: VersionPreview) -> some View {
        let isMain = id.wrappedValue == versions.index.main
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Picker("Version", selection: id) {
                    ForEach(versions.index.versions) { version in
                        Text(version.name).tag(version.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(isMain ? "\(Timecode.short(from: preview.duration)) · main" : Timecode.short(from: preview.duration))
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            PlayerSurface(player: preview.player)
                .background(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: isMain ? [] : Theme.Stroke.dash))
                    .padding(-4))
                .aspectRatio(16 / 10, contentMode: .fit)
                .onTapGesture { preview.toggle() }
            if let problem = preview.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Theme.error)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func playBoth() {
        if left.isPlaying || right.isPlaying {
            left.player.pause()
            right.player.pause()
        } else {
            left.player.seek(to: .zero)
            right.player.seek(to: .zero)
            left.player.play()
            right.player.play()
        }
        left.refresh()
        right.refresh()
    }
}

/// One version played on its own: its cuts, zooms, blurs and sound over
/// the take's video, built like the editor's preview.
@MainActor
final class VersionPreview: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var problem: String?

    func toggle() {
        if player.rate != 0 { player.pause() } else { player.play() }
        refresh()
    }

    func refresh() { isPlaying = player.rate != 0 }

    func load(take: Take, folder: URL) async {
        player.pause()
        do {
            let asset = AVURLAsset(url: take.screenURL)
            let sourceDuration = try await asset.load(.duration).seconds
            let edits = (try? EditList.load(from: folder.appendingPathComponent("edits.json"), sourceDuration: sourceDuration))
                ?? EditList(sourceDuration: sourceDuration)
            let spans = edits.keptSpans
            let composition = try await PreviewComposition.make(from: asset, keeping: spans)
            let timeline = ExportTimeline(keep: spans.map { $0.start..<$0.end }, sourceDuration: sourceDuration, frameRate: 0)
            let words = (try? Transcript.read(from: take.transcriptURL))?.words.map(\.span) ?? []
            let sound = (try? SoundPlan.load(from: folder.appendingPathComponent("sound.json"))) ?? SoundPlan()
            let voice = composition.tracks(withMediaType: .audio).map(\.trackID)
            let added = await SoundComposer.add(sound, timeline: timeline, words: words, to: composition)
            let redos = ((try? RedoList.load(from: folder.appendingPathComponent("redos.json"))) ?? RedoList()).playing
            let redone = await RedoComposer.add(redos, take: take, timeline: timeline, to: composition)
            let item = AVPlayerItem(asset: composition)
            item.audioTimePitchAlgorithm = .spectral
            let muted: [AVMutableAudioMixInputParameters] = redone.mutes.isEmpty ? [] : voice.map { id in
                let parameters = AVMutableAudioMixInputParameters()
                parameters.trackID = id
                RedoComposer.mute(parameters, during: redone.mutes)
                return parameters
            }
            let inputs = added.parameters + redone.parameters + muted
            if !inputs.isEmpty {
                let mix = AVMutableAudioMix()
                mix.inputParameters = inputs
                item.audioMix = mix
            }
            if let track = composition.tracks(withMediaType: .video).first {
                let zooms = (try? ZoomList.load(from: folder.appendingPathComponent("zooms.json"))) ?? ZoomList()
                let blurs = (try? BlurList.load(from: folder.appendingPathComponent("blurs.json"))) ?? BlurList()
                let cursor = (try? EventLog.read(from: take.eventsURL))?.cursorPath ?? []
                let effects = FrameEffects.export(zooms: zooms, blurs: blurs, cursor: cursor, timeline: timeline)
                if !effects.isEmpty {
                    let natural = try await track.load(.naturalSize)
                    let scale = min(1, 1280 / max(natural.width, natural.height, 1))
                    let video = AVMutableVideoComposition()
                    video.customVideoCompositorClass = FrameCompositor.self
                    video.renderSize = CGSize(width: (natural.width * scale / 2).rounded() * 2,
                                              height: (natural.height * scale / 2).rounded() * 2)
                    video.frameDuration = CMTime(value: 1, timescale: 30)
                    video.instructions = [
                        FrameInstruction(timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                                         trackID: track.trackID, overlays: [], effects: effects),
                    ]
                    item.videoComposition = video
                }
            }
            player.replaceCurrentItem(with: item)
            duration = edits.outputDuration
            problem = added.problem
        } catch {
            problem = "Couldn't play this version: \(error.localizedDescription)"
        }
        refresh()
    }
}

import AVFoundation
import SwiftUI
import VisionOneKit

/// "Try in a copy" for one take, on the same versions.json the Desk
/// and agents use. The version you edit is always the main cut
/// (edits.json), so export, Home and agents read it as before. Trying a
/// copy keeps the cut you had as a copy beside it; switching makes
/// another version the main cut and keeps the one you left.
/// Copies hold the cuts; zooms, blurs, sound and redos are shared.
@MainActor
final class VersionsModel: ObservableObject {
    @Published private(set) var versions: TakeVersions
    @Published var error: String?

    let take: Take
    private weak var editor: EditorModel?

    init(editor: EditorModel) {
        self.editor = editor
        take = editor.take
        versions = TakeVersions.load(for: editor.take)
    }

    var main: TakeVersion { versions.main }
    var hasCopies: Bool { !versions.copies.isEmpty }

    func name(_ id: UUID) -> String { versions.version(id)?.name ?? "Version" }

    /// Keeps the cut you have as a copy and goes on editing a copy of it.
    func tryCopy(note: String? = nil) {
        perform { versions in
            let kept = versions.main
            let copy = try versions.makeCopy(in: take)
            try versions.makeMain(copy.id, in: take)
            // The cut you had keeps its own name.
            versions.rename(kept.id, to: kept.name)
        }
    }

    /// Makes another version the main cut, the one you edit and export.
    func use(_ id: UUID) {
        guard id != versions.main.id else { return }
        perform { versions in
            let left = versions.main
            try versions.makeMain(id, in: take)
            versions.rename(left.id, to: left.name)
        }
    }

    func delete(_ id: UUID) { perform { try $0.remove(id, in: take) } }

    /// Picks up copies an agent made while the editor was open.
    func refresh() { versions = TakeVersions.load(for: take) }

    private func perform(_ change: (inout TakeVersions) throws -> Void) {
        var next = TakeVersions.load(for: take)
        do {
            try change(&next)
            try next.write(for: take)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        versions = TakeVersions.load(for: take)
        // Another cut may be in edits.json now.
        editor?.reloadFiles()
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
                ForEach(model.versions.versions) { version in
                    Button {
                        model.use(version.id)
                    } label: {
                        if version.isMain {
                            Label(title(version), systemImage: "checkmark")
                        } else {
                            Text(title(version))
                        }
                    }
                }
            }
            Divider()
            Button("Try in a copy") { model.tryCopy() }
            Button("Compare versions…", action: compare)
                .disabled(!model.hasCopies)
            if model.hasCopies {
                Menu("Delete a copy") {
                    ForEach(model.versions.copies) { copy in
                        Button(copy.name) { model.delete(copy.id) }
                            .disabled(copy.locked)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.main.name).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: Theme.Size.controlSmall + 2)
            .overlay(Capsule().strokeBorder(Theme.text, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The version you're editing. Try a big change in a copy and this one stays safe.")
        .onAppear { model.refresh() }
    }

    private func title(_ version: TakeVersion) -> String {
        var parts = [version.name]
        if version.isMain { parts.append("editing") }
        if version.locked { parts.append("exported, locked") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Compare

/// Two versions side by side. Play both together, then use one or keep
/// both.
struct CompareView: View {
    @ObservedObject var versions: VersionsModel
    let take: Take
    let done: () -> Void

    @State private var leftID: UUID
    @State private var rightID: UUID
    @StateObject private var left = VersionPreview()
    @StateObject private var right = VersionPreview()

    init(versions: VersionsModel, take: Take, done: @escaping () -> Void) {
        self.versions = versions
        self.take = take
        self.done = done
        let main = versions.main.id
        _leftID = State(initialValue: main)
        _rightID = State(initialValue: versions.versions.copies.last?.id ?? main)
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
                if rightID != versions.main.id {
                    Button("Use \(versions.name(rightID))") {
                        versions.use(rightID)
                        done()
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                }
                Button("Keep both", action: done)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Text("The version you use is the one you edit, export and see in Home. The other stays as a copy.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Space.lg)
        .frame(minWidth: 820, minHeight: 460)
        .background(Theme.paper)
        .task(id: leftID) { await left.load(take: take, edits: url(leftID)) }
        .task(id: rightID) { await right.load(take: take, edits: url(rightID)) }
        .onDisappear {
            left.player.pause()
            right.player.pause()
        }
    }

    private func url(_ id: UUID) -> URL {
        versions.versions.version(id).map { TakeVersions.url(of: $0, in: take) } ?? take.editsURL
    }

    private func side(id: Binding<UUID>, preview: VersionPreview) -> some View {
        let isMain = id.wrappedValue == versions.main.id
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Picker("Version", selection: id) {
                    ForEach(versions.versions.versions) { version in
                        Text(version.name).tag(version.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(isMain ? "\(Timecode.short(from: preview.duration)) · editing" : Timecode.short(from: preview.duration))
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

/// One version played on its own: its cuts, with the take's zooms,
/// blurs, sound and redos, built like the editor's preview.
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

    func load(take: Take, edits editsURL: URL) async {
        player.pause()
        do {
            let asset = AVURLAsset(url: take.screenURL)
            let sourceDuration = try await asset.load(.duration).seconds
            let edits = (try? EditList.load(from: editsURL, sourceDuration: sourceDuration))
                ?? EditList(sourceDuration: sourceDuration)
            let spans = edits.keptSpans
            let composition = try await PreviewComposition.make(from: asset, keeping: spans, take: take)
            let timeline = ExportTimeline(keep: spans.map { $0.start..<$0.end }, sourceDuration: sourceDuration, frameRate: 0)
            let words = (try? Transcript.read(from: take.transcriptURL))?.words.map(\.span) ?? []
            let sound = (try? SoundPlan.load(from: take.soundURL)) ?? SoundPlan()
            let voice = composition.tracks(withMediaType: .audio).map(\.trackID)
            let added = await SoundComposer.add(sound, timeline: timeline, words: words, to: composition)
            let redos = ((try? RedoList.load(from: take.redosURL)) ?? RedoList()).playing
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
                let zooms = (try? ZoomList.load(from: take.zoomsURL)) ?? ZoomList()
                let blurs = (try? BlurList.load(from: take.blursURL)) ?? BlurList()
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

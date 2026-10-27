import AVFoundation
import AppKit
import UniformTypeIdentifiers
import VisionOneKit

/// Music and sound effects in the editor. Every change goes through
/// `applySound`, so it is saved to sound.json, can be undone and is
/// heard in the preview straight away.
extension EditorModel {
    /// The kept parts of the take laid end to end, as the preview plays them.
    var outputTimeline: ExportTimeline {
        ExportTimeline(keep: edits.keptSpans.map { $0.start..<$0.end }, sourceDuration: edits.sourceDuration, frameRate: 0)
    }

    /// The music's volume over the edited video, for drawing the dips.
    var musicEnvelope: MusicEnvelope? {
        guard let bed = sound.music else { return nil }
        let timeline = outputTimeline
        let speech = Speech.outputRegions(words: wordSpans, timeline: timeline, bridge: DuckingSettings().bridge)
        return MusicEnvelope(duration: timeline.duration, bed: bed, speech: speech)
    }

    var proposedEffectCount: Int {
        sound.effects.filter { $0.state == .proposed }.count
    }

    // MARK: Music

    func setMusic(_ bed: MusicBed?) {
        var next = sound
        if var bed, let old = next.music {
            // Switching tracks keeps the level and duck you set.
            bed.levelDB = old.levelDB
            bed.duckDB = old.duckDB
            next.music = bed
        } else {
            next.music = bed
        }
        applySound(next, actionName: bed == nil ? "Remove Music" : "Choose Music")
    }

    func chooseMusicFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose music you have the rights to use in your video."
        panel.prompt = "Use Music"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setMusic(.file(at: url))
    }

    /// Changes the plan while a slider or drag moves, without saving.
    func previewSound(_ change: (inout SoundPlan) -> Void) {
        var next = sound
        change(&next)
        applySound(next, actionName: "", commit: false)
    }

    /// Saves what `previewSound` changed since `start`, as one undo step.
    func commitSound(from start: SoundPlan?, actionName: String) {
        applySound(sound, actionName: actionName, from: start)
    }

    // MARK: Effects

    func setEnergy(_ energy: Energy) {
        var next = sound
        next.setEnergy(energy, words: wordSpans, edits: edits)
        applySound(next, actionName: "Energy")
    }

    /// Adds an effect at the playhead, accepted, as the user's own.
    func addEffect(_ soundID: String) {
        var next = sound
        next.effects.append(PlacedEffect(soundID: soundID, at: sourceTime))
        applySound(next, actionName: "Add Sound Effect")
        EffectAudition.play(soundID)
    }

    func setEffectState(_ state: PlacedEffect.State, for id: UUID) {
        var next = sound
        next.setState(state, for: id)
        applySound(next, actionName: state == .accepted ? "Accept Sound Effect" : "Skip Sound Effect")
    }

    func changeEffectSound(_ id: UUID, to soundID: String) {
        var next = sound
        guard let i = next.effects.firstIndex(where: { $0.id == id }) else { return }
        next.effects[i].soundID = soundID
        next.effects[i].isManual = true
        applySound(next, actionName: "Change Sound Effect")
        EffectAudition.play(soundID)
    }

    func removeEffect(_ id: UUID) {
        var next = sound
        next.remove(id: id)
        applySound(next, actionName: "Remove Sound Effect")
    }

    func acceptAllEffects() {
        var next = sound
        next.acceptAllProposed()
        applySound(next, actionName: "Accept All Sound Effects")
    }
}

/// Plays one effect on its own, so you can hear it before you use it.
@MainActor
enum EffectAudition {
    private static var player: AVAudioPlayer?

    static func play(_ soundID: String) {
        Task {
            guard let url = try? await SoundFiles.url(forLibrarySound: soundID),
                  let next = try? AVAudioPlayer(contentsOf: url) else { return }
            player?.stop()
            player = next
            next.volume = 0.6
            next.play()
        }
    }

    static func stop() {
        player?.stop()
        player = nil
    }
}

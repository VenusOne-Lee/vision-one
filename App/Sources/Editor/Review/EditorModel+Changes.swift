import Foundation
import VisionOneKit

/// The Changes list: every AI suggestion grouped into rows with a switch.
/// Cuts go through `apply`, zooms and blurs through the effects model and
/// sound effects through `applySound`, so each switch is one undo step
/// and is saved straight away.
extension EditorModel {
    /// The rows, built from what's open now.
    var changeGroups: [ChangeGroup] {
        ChangeSummary.groups(edits: edits, words: words, zooms: effects.zooms,
                             blurs: effects.blurs, sound: sound)
    }

    /// Suggestions still waiting for an answer, across cuts, zooms,
    /// blurs and sound effects.
    var proposedChangeCount: Int {
        proposedCount + effects.proposedCount + proposedEffectCount
    }

    /// On accepts the whole row (solid); off turns it all down (muted).
    func setChange(_ kind: ChangeGroup.Kind, on: Bool) {
        let state: Cut.State = on ? .accepted : .rejected
        let actionName = on ? "Accept \(kind.noun)" : "Turn Off \(kind.noun)"
        switch kind {
        case .zooms:
            var next = effects.zooms
            next.setState(state, forChange: kind)
            guard next != effects.zooms else { return }
            effects.apply(zooms: next, actionName: actionName)
        case .blurs:
            var next = effects.blurs
            next.setState(state, forChange: kind)
            guard next != effects.blurs else { return }
            effects.apply(blurs: next, actionName: actionName)
        case .soundEffects:
            var next = sound
            next.setState(on ? .accepted : .rejected, forChange: kind)
            applySound(next, actionName: actionName)
        case .fillers, .pauses, .retakes, .deadAir, .trims:
            var next = edits
            next.setState(state, forChange: kind)
            guard next != edits else { return }
            apply(next, actionName: actionName)
        }
    }

    /// "Accept all" in the Changes list: every dashed row goes solid, as
    /// one undo step.
    func acceptAllChanges() {
        guard proposedChangeCount > 0 else { return }
        undoManager.beginUndoGrouping()
        if proposedCount > 0 { acceptAllProposed() }
        if effects.proposedCount > 0 { effects.acceptAllProposed() }
        if proposedEffectCount > 0 { acceptAllEffects() }
        undoManager.setActionName("Accept All")
        undoManager.endUndoGrouping()
    }

    /// Something "Undo all" would change.
    var canUndoAll: Bool {
        edits.cuts.contains { $0.state != .rejected }
            || effects.zooms.zooms.contains { $0.state != .rejected }
            || sound.effects.contains { $0.state != .rejected }
    }

    /// "Undo all": back to the take as recorded, as one undo step. Your
    /// own cuts go, every suggested cut, zoom and sound effect is turned
    /// off. Blurs stay, so a secret never shows because of this button;
    /// turn them off in Changes if you really mean to.
    func undoAll() {
        guard canUndoAll else { return }
        undoManager.beginUndoGrouping()
        var nextEdits = edits
        nextEdits.revertAll()
        if nextEdits != edits { apply(nextEdits, actionName: "Undo All") }
        var nextZooms = effects.zooms
        nextZooms.rejectAll()
        if nextZooms != effects.zooms { effects.apply(zooms: nextZooms, actionName: "Undo All") }
        var nextSound = sound
        nextSound.rejectAllEffects()
        if nextSound != sound { applySound(nextSound, actionName: "Undo All") }
        undoManager.setActionName("Undo All")
        undoManager.endUndoGrouping()
    }
}

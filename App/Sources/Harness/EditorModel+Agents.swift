import Foundation
import VisionOneKit

extension EditorModel {
    /// Keep or Undo on an agent's receipt, as one undoable step. Undone
    /// cuts stay in the list as turned down, so they aren't suggested again.
    func settleAgentCuts(_ ids: [UUID], keep: Bool, agent: String) {
        pickUpOutsideCuts()
        let open = Set(ids)
        guard edits.cuts.contains(where: { open.contains($0.id) && $0.state == .proposed }) else { return }
        var next = edits
        for id in ids where next.cuts.contains(where: { $0.id == id && $0.state == .proposed }) {
            next.setState(keep ? .accepted : .rejected, for: id)
        }
        apply(next, actionName: keep ? "Keep \(agent)'s Cuts" : "Undo \(agent)'s Cuts")
    }
}

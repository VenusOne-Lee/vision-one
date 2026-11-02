import SwiftUI
import VisionOneKit

/// Transient approval state never survives a take/destination switch. Only
/// explicitly edited words are persisted; generated drafts remain the fallback.
@MainActor
final class PostDraftControl: ObservableObject {
    let take: Take
    let destination: String
    @Published private(set) var manualText: String?
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    @Published var open = false
    @Published var asking = false
    @Published var posted = false

    private var observer: NSObjectProtocol?

    init(take: Take, destination: String) {
        self.take = take
        self.destination = destination
        reload()
        // Another view editing the same draft (the Post copy form and the
        // network row share "x") keeps this one current.
        observer = NotificationCenter.default.addObserver(forName: .postDraftChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let sender = note.object as? PostDraftControl, sender !== self,
                      sender.take.folder == self.take.folder, sender.destination == self.destination else { return }
                self.manualText = sender.manualText
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        do {
            let drafts = try PostDrafts.read(for: take)
            manualText = drafts[destination]
            loaded = true
            problem = nil
        } catch {
            loaded = false
            problem = "Couldn't read saved post copy: \(error.localizedDescription)"
        }
    }

    func edit(_ text: String) {
        guard loaded else { return }
        manualText = text
        asking = false
        posted = false
        save()
    }

    func save() {
        guard loaded, let manualText else { return }
        do {
            try PostDrafts.save(manualText, destination: destination, for: take)
            problem = nil
            NotificationCenter.default.post(name: .postDraftChanged, object: self)
        } catch {
            problem = "Couldn't save post copy. Your draft is still here: \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    static let postDraftChanged = Notification.Name("VisionOnePostDraftChanged")
}

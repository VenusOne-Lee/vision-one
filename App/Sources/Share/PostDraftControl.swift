import SwiftUI
import VisionOneKit

/// Transient approval state never survives a take/destination switch. Only
/// explicitly edited words are persisted; generated drafts remain the fallback.
@MainActor
final class PostDraftControl: ObservableObject {
    let take: Take
    let destination: String
    @Published private(set) var override: String?
    @Published private(set) var problem: String?
    @Published private(set) var loaded = false
    @Published var open = false
    @Published var asking = false
    @Published var posted = false

    init(take: Take, destination: String) {
        self.take = take
        self.destination = destination
        reload()
    }

    func reload() {
        do {
            let drafts = try PostDrafts.read(for: take)
            override = drafts[destination]
            loaded = true
            problem = nil
        } catch {
            loaded = false
            problem = "Couldn't read saved post copy: \(error.localizedDescription)"
        }
    }

    func edit(_ text: String) {
        guard loaded else { return }
        override = text
        asking = false
        posted = false
        save()
    }

    func save() {
        guard loaded, let override else { return }
        do {
            try PostDrafts.save(override, destination: destination, for: take)
            problem = nil
        } catch {
            problem = "Couldn't save post copy. Your draft is still here: \(error.localizedDescription)"
        }
    }
}

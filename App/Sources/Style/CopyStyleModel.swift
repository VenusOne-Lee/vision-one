import AppKit
import UniformTypeIdentifiers
import SwiftUI
import VisionOneKit

/// Drives the Copy a style window: take a file or link, read it, show
/// the traits, save the template.
@MainActor
final class CopyStyleModel: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case reading(progress: Double)
        case ready
        case saved(URL)
    }

    @Published private(set) var phase: Phase = .waiting
    @Published var pasted = ""
    @Published private(set) var source: StyleSource?
    /// What has been found so far, while reading, and the result after.
    @Published private(set) var profile: StyleProfile?
    @Published var copying: Set<StyleTraitID> = []
    @Published var title = ""
    @Published private(set) var problem: String?
    /// True while the ladder names the template.
    @Published private(set) var naming = false

    private var task: Task<Void, Never>?

    /// What the paste field would open, for the line under it.
    var pastedSource: StyleSource? { StyleSource.classify(pasted) }

    // MARK: - Input

    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video to copy the style of"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard let source = StyleSource.classify(url) else {
            problem = "That isn't a video Vision One can read. Try an MP4 or MOV file."
            return
        }
        start(source)
    }

    func openPasted() {
        guard let source = pastedSource else {
            problem = pasted.isEmpty ? nil : "That isn't a link or a video file Vision One can open."
            return
        }
        start(source)
    }

    private func start(_ source: StyleSource) {
        problem = nil
        self.source = source
        guard source.readsDirectly else {
            // Links on video sites play in a window while they're read;
            // that comes next. Until then, a file they saved works.
            phase = .waiting
            problem = "Reading \(source.label) links as they play is coming next. For now, drop the video file here (TikTok and YouTube Studio let you download your own)."
            return
        }
        task?.cancel()
        profile = nil
        phase = .reading(progress: 0)
        let label = source.label
        let url = source.url
        task = Task { [weak self] in
            do {
                let input = try await StyleSampler.read(url) { progress, partial in
                    guard let self, case .reading = self.phase else { return }
                    self.phase = .reading(progress: progress)
                    self.profile = StyleScanner.profile(from: partial, source: label)
                }
                let profile = await Task.detached(priority: .userInitiated) {
                    StyleScanner.profile(from: input, source: label)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.finish(with: profile)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.phase = .waiting
                self.problem = error.localizedDescription
            }
        }
    }

    private func finish(with profile: StyleProfile) {
        self.profile = profile
        copying = Set(profile.traits.filter(\.copiedByDefault).map(\.id))
        title = profile.suggestedTitle
        phase = .ready
        Task { await nameOnDevice(profile) }
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = .waiting
        profile = nil
    }

    // MARK: - Result

    func toggle(_ trait: StyleTraitID) {
        if copying.contains(trait) { copying.remove(trait) } else { copying.insert(trait) }
    }

    /// Names it with the AI ladder only when the model is on this Mac, so
    /// nothing asks for approval by itself. A cloud rung waits for the
    /// "Suggest a name" button.
    private func nameOnDevice(_ profile: StyleProfile) async {
        let ladder = AIServices.shared.ladder()
        guard let provider = await ladder.provider(for: .styleName), !provider.leavesDevice else { return }
        await suggestName()
    }

    /// Whether a model is set up to name it.
    func canSuggestName() async -> Bool {
        await AIServices.shared.ladder().provider(for: .styleName) != nil
    }

    func suggestName() async {
        guard let profile, !naming else { return }
        let suggestedBefore = title == profile.suggestedTitle
        naming = true
        let name = await StyleNamer(ladder: AIServices.shared.ladder()).name(profile)
        naming = false
        // Don't overwrite a name the person typed meanwhile.
        if suggestedBefore || title.isEmpty { title = name.title }
    }

    func save() {
        guard let profile else { return }
        do {
            let style = CopiedStyle(profile: profile, copying: copying)
            let folder = try UserTemplates.save(style, title: title)
            phase = .saved(folder)
            NotificationCenter.default.post(name: .userTemplatesChanged, object: nil)
        } catch {
            problem = "Couldn't save the template. \(error.localizedDescription)"
        }
    }

    func reset() {
        stop()
        source = nil
        pasted = ""
        problem = nil
        title = ""
        copying = []
    }
}

extension Notification.Name {
    /// Posted when Copy a style saves a template, so Home lists it.
    static let userTemplatesChanged = Notification.Name("VisionOneUserTemplatesChanged")
}

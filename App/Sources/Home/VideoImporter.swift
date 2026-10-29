import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VisionOneKit

/// Local video import, separate from copying a reference video's style.
@MainActor
final class VideoImporter: ObservableObject {
    static let shared = VideoImporter()
    @Published private(set) var isImporting = false
    @Published private(set) var problem: String?
    private var work: Task<Void, Never>?

    func choose(onImported: @escaping (Take) -> Void) {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a video into an editable task"
        panel.prompt = "Import video"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.open(url, onImported: onImported) }
        }
    }

    func open(_ url: URL, onImported: @escaping (Take) -> Void) {
        guard !isImporting else { return }
        isImporting = true
        problem = nil
        work = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isImporting = false
                work = nil
            }
            do {
                try await Self.validate(url)
                try Task.checkCancellation()
                // Cancellation is forwarded to the file transaction, including large files.
                let copy = Task.detached(priority: .userInitiated) {
                    try VideoImport.copy(url, into: .standard) { try Task.checkCancellation() }
                }
                let take = try await withTaskCancellationHandler {
                    try await copy.value
                } onCancel: { copy.cancel() }
                // After commit, always open the valid take even if cancellation arrived late.
                onImported(take)
                Transcriber.shared.transcribe(take)
            } catch is CancellationError {
                // The transaction removes staging files. The original is untouched.
            } catch {
                problem = "Couldn't import this video. \(error.localizedDescription)"
            }
        }
    }

    static func validate(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !tracks.isEmpty,
              try await asset.load(.isReadable) else { throw ImportError.invalidVideo }
    }

    func cancel() { work?.cancel() }
    func clearProblem() { problem = nil }

    private enum ImportError: LocalizedError {
        case invalidVideo
        var errorDescription: String? { "Choose a readable video with at least one frame. Videos without audio can still be edited and exported." }
    }
}

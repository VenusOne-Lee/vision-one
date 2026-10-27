import AppKit
import VisionOneKit

/// Captions in South Africa's languages, translated through the AI ladder,
/// which asks before anything leaves the Mac. See docs/LANGUAGES.md.
@MainActor
final class LanguagesModel: ObservableObject {
    enum Work: Equatable {
        case idle
        case translating(SALanguage, Double)
        case failed(String)
        case done(String)

        var isBusy: Bool {
            switch self {
            case .translating: return true
            default: return false
            }
        }
    }

    let take: Take

    @Published private(set) var spoken: SALanguage = .english
    @Published private(set) var translated: [SALanguage] = []
    @Published private(set) var work: Work = .idle
    @Published var captionLanguage: SALanguage? {
        didSet {
            var settings = take.loadCaptionSettings()
            settings.language = captionLanguage
            try? take.saveCaptionSettings(settings)
        }
    }

    private var task: Task<Void, Never>?

    init(take: Take) {
        self.take = take
        captionLanguage = take.loadCaptionSettings().language
        refresh()
    }

    /// Languages to offer captions in: everything but the one spoken.
    var targets: [SALanguage] {
        (SALanguage.captionTargets + [.english]).filter { $0 != spoken }
    }

    func refresh() {
        if let transcript = try? Transcript.read(from: take.transcriptURL) {
            spoken = SALanguage(code: transcript.language) ?? .english
        }
        translated = take.captionLanguages()
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Captions

    func translate(_ language: SALanguage) {
        guard !work.isBusy else { return }
        let take = take
        let spoken = spoken
        let ladder = AIServices.shared.ladder()
        let brand = BrandStore.shared.kit
        let keywords = take.loadCaptionSettings().keywordNames
        let board = AIServices.shared.jobs
        let job = AgentJob(agent: .editor, title: "Captions in \(language.name)", take: take,
                           steps: ["Read the transcript", "Translate into \(language.name)", "Make the captions"])
        work = .translating(language, 0)
        task = Task {
            await board.add(job)
            do {
                await board.step(job.id, 0)
                let transcript = try Transcript.read(from: take.transcriptURL)
                let previous = try? TranslationFile.read(from: take.translationURL(language))
                await board.step(job.id, 1)
                let translator = CaptionTranslator(ladder: ladder)
                let file = try await translator.translate(
                    transcript, to: language, from: spoken,
                    keep: CaptionTranslator.keepAsIs(brand: brand, keywords: keywords),
                    context: brand.tagline, previous: previous) { fraction in
                        Task { @MainActor in
                            if case .translating(language, _) = self.work { self.work = .translating(language, fraction) }
                        }
                    }
                await board.step(job.id, 2)
                try take.saveTranslation(file, duration: transcript.duration, audioTrack: transcript.audioTrack)
                let receipt = AgentReceipt.translation(file)
                await board.finish(job.id, receipt: receipt, changes: [])
                work = .done(receipt)
            } catch is CancellationError {
                await board.cancel(job.id)
                work = .idle
            } catch {
                let message = AgentsModel.message(for: error)
                await board.fail(job.id, message)
                work = .failed(message)
            }
            refresh()
        }
    }

    func remove(_ language: SALanguage) {
        take.removeTranslation(language)
        if captionLanguage == language { captionLanguage = nil }
        refresh()
    }
}

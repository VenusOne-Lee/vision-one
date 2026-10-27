import Foundation

extension AITask {
    /// Translating a take's sentences for captions.
    public static let translateCaptions = AITask("captions.translate")
}

/// Translates a take's sentences for captions through the AI ladder, a
/// batch at a time. Each sentence keeps its time, names are kept as they
/// are, and lines the person fixed by hand are never sent again.
public struct CaptionTranslator: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case nothingToTranslate
        /// The model answered with a different number of lines.
        case lineCount(expected: Int, got: Int)

        public var errorDescription: String? {
            switch self {
            case .nothingToTranslate: return "This take has no words to translate yet. Wait for the transcript, then try again."
            case let .lineCount(expected, got):
                return "The translation came back with \(got) lines instead of \(expected). Try again, or pick another AI in Settings → AI."
            }
        }
    }

    /// About 1,500 tokens of sentences per request, so a batch and its
    /// reply fit every cloud rung comfortably.
    public static let batchCharacters = 6_000

    public let ladder: AILadder

    /// Apple's on-device model doesn't write any South African language
    /// except English, so it is left out; every other rung stays as set.
    public init(ladder: AILadder) {
        self.ladder = AILadder(providers: ladder.providers.filter { $0.id != .appleOnDevice },
                               gate: ladder.gate, settings: ladder.settings)
    }

    /// Names, products and places that must come through unchanged.
    public static func keepAsIs(brand: BrandKit? = nil, keywords: [String] = []) -> [String] {
        var names: [String] = []
        if let brand {
            names.append(brand.name)
            names.append(brand.displaySite)
        }
        names += keywords
        names += ["Vision One", "Version One", "Joburg", "Jozi", "Mzansi", "Eskom", "SnapScan", "WhatsApp"]
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The sentences to translate: every sentence in the take, cut or
    /// not, so later edits don't need a new translation.
    public static func sentences(of transcript: Transcript) -> [SpokenSentence] {
        transcript.sentences()
    }

    /// Groups sentences into batches of about `batchCharacters`.
    public static func batches(_ sentences: [SpokenSentence], limit: Int = batchCharacters) -> [[SpokenSentence]] {
        var result: [[SpokenSentence]] = []
        var current: [SpokenSentence] = []
        var size = 0
        for sentence in sentences {
            if !current.isEmpty, size + sentence.text.count > limit {
                result.append(current)
                current = []
                size = 0
            }
            current.append(sentence)
            size += sentence.text.count + 8
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The request for one batch.
    public static func request(for batch: [SpokenSentence], to language: SALanguage, from spoken: SALanguage = .english,
                               keep: [String], context: String? = nil) -> AIRequest {
        var instructions = [
            "Translate captions for a short screen recording from \(spoken.promptName) into \(language.promptName).",
            "Write the way people speak in South Africa today: plain, natural, not formal or old-fashioned.",
            "Keep each line short enough to read on screen. Keep numbers, prices in rand, times and web addresses as they are.",
            "Translate every line, in order. Reply with exactly one translated line for each numbered line, with the same number.",
        ]
        if !keep.isEmpty {
            instructions.append("Never translate these names; copy them exactly: \(keep.joined(separator: ", ")).")
        }
        if let context, !context.isEmpty {
            instructions.append("What the video is about: \(context)")
        }
        let input = batch.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        return AIRequest(task: .translateCaptions,
                         summary: "Translate \(batch.count) caption \(batch.count == 1 ? "line" : "lines") into \(language.name)",
                         instructions: instructions.joined(separator: "\n"),
                         input: input,
                         format: .json(shape: #"{"lines": [{"n": 1, "text": "..."}]}"#))
    }

    struct Reply: Decodable {
        struct Line: Decodable {
            var n: Int
            var text: String
        }
        var lines: [Line]
    }

    /// Lines from a model's reply, in the batch's order. Numbers are
    /// trusted over order; a missing number fails the batch so nothing
    /// lands on the wrong sentence.
    public static func parse(_ response: AIResponse, batch: [SpokenSentence]) throws -> [TranslatedLine] {
        let reply = try response.decode(Reply.self)
        var byNumber: [Int: String] = [:]
        for line in reply.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if byNumber[line.n] == nil, !text.isEmpty { byNumber[line.n] = text }
        }
        var lines: [TranslatedLine] = []
        for (i, sentence) in batch.enumerated() {
            guard let text = byNumber[i + 1] else {
                throw Failure.lineCount(expected: batch.count, got: byNumber.count)
            }
            lines.append(TranslatedLine(start: sentence.start, end: sentence.end, source: sentence.text, text: text))
        }
        return lines
    }

    /// Translates the whole take. Lines in `previous` the person fixed by
    /// hand are kept and not sent. `progress` gets 0...1 after each batch.
    public func translate(_ transcript: Transcript, to language: SALanguage, from spoken: SALanguage = .english,
                          keep: [String] = [], context: String? = nil, previous: TranslationFile? = nil,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> TranslationFile {
        let all = Self.sentences(of: transcript)
        guard !all.isEmpty else { throw Failure.nothingToTranslate }
        let kept = previous?.editedBySource ?? [:]
        let toSend = all.filter { kept[$0.text] == nil }
        var lines: [TranslatedLine] = all.compactMap { sentence in
            kept[sentence.text].map {
                TranslatedLine(start: sentence.start, end: sentence.end, source: sentence.text, text: $0.text, edited: true)
            }
        }
        var engine = previous?.engine ?? ""
        let batches = Self.batches(toSend)
        for (i, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let response = try await ladder.complete(Self.request(for: batch, to: language, from: spoken,
                                                                  keep: keep, context: context))
            lines += try Self.parse(response, batch: batch)
            engine = Self.engineName(response)
            progress?(Double(i + 1) / Double(batches.count))
        }
        lines.sort { $0.start < $1.start }
        return TranslationFile(language: language, engine: engine, lines: lines)
    }

    /// "chatgpt · gpt-6.1-terra"
    static func engineName(_ response: AIResponse) -> String {
        response.model.isEmpty ? response.provider.rawValue : "\(response.provider.rawValue) · \(response.model)"
    }
}

extension AgentReceipt {
    /// "Translated 18 lines into isiZulu. Ask an isiZulu speaker to read it before you post."
    public static func translation(_ file: TranslationFile) -> String {
        let count = file.lines.count
        var text = "Translated \(count) \(count == 1 ? "line" : "lines") into \(file.language.name)."
        if file.language.support.translate.quality.wantsSpeakerCheck {
            text += " Ask a \(file.language.name) speaker to read it before you post."
        }
        return text
    }
}

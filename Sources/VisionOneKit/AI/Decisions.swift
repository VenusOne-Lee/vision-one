import Foundation

/// One question for a decision request, shaped like OpenAI's Decisions API
/// so the same request can go there natively or to any other rung.
public struct DecisionQuestion: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Yes or no, answered as a probability of yes.
        case predicate
        /// One of `choices`.
        case choice
        /// A level from `levels`, lowest first, answered as a 0-based index
        /// that may fall between levels.
        case score
    }

    public struct Choice: Codable, Equatable, Sendable {
        public var value: String
        public var description: String
        public init(value: String, description: String) {
            self.value = value
            self.description = description
        }
    }

    public struct Level: Codable, Equatable, Sendable {
        public var label: String
        public var description: String
        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    /// Unique in its request; answers come back by name.
    public var name: String
    public var kind: Kind
    public var instructions: String
    public var choices: [Choice]
    public var levels: [Level]

    public static func predicate(_ name: String, _ instructions: String) -> DecisionQuestion {
        DecisionQuestion(name: name, kind: .predicate, instructions: instructions, choices: [], levels: [])
    }

    public static func choice(_ name: String, _ instructions: String, _ choices: [Choice]) -> DecisionQuestion {
        DecisionQuestion(name: name, kind: .choice, instructions: instructions, choices: choices, levels: [])
    }

    public static func score(_ name: String, _ instructions: String, _ levels: [Level]) -> DecisionQuestion {
        DecisionQuestion(name: name, kind: .score, instructions: instructions, choices: [], levels: levels)
    }

    public init(name: String, kind: Kind, instructions: String, choices: [Choice], levels: [Level]) {
        self.name = name
        self.kind = kind
        self.instructions = instructions
        self.choices = choices
        self.levels = levels
    }
}

public struct DecisionAnswer: Codable, Equatable, Sendable {
    public var name: String
    /// Predicate: chance of yes, 0...1.
    public var probability: Double?
    /// Choice: the value picked.
    public var choice: String?
    /// Score: 0-based level index, may be fractional.
    public var score: Double?
    public var confidence: Double?
    /// True when the model refused this one.
    public var refused: Bool

    public init(name: String, probability: Double? = nil, choice: String? = nil, score: Double? = nil,
                confidence: Double? = nil, refused: Bool = false) {
        self.name = name
        self.probability = probability
        self.choice = choice
        self.score = score
        self.confidence = confidence
        self.refused = refused
    }
}

public struct DecisionRequest: Sendable {
    public var task: AITask
    public var summary: String
    /// Shared context for every question: the purpose, the ask, an outline.
    /// Keep each question self-contained so small rungs can take them in batches.
    public var input: String
    public var questions: [DecisionQuestion]

    public init(task: AITask, summary: String, input: String, questions: [DecisionQuestion]) {
        self.task = task
        self.summary = summary
        self.input = input
        self.questions = questions
    }

    public var estimatedTokens: Int {
        AITokens.estimate(input) + questions.reduce(0) { $0 + AITokens.estimate($1.instructions) + 20 }
    }
}

public struct DecisionResult: Sendable {
    public var answers: [DecisionAnswer]
    public var provider: AIProviderID
    public var model: String

    public init(answers: [DecisionAnswer], provider: AIProviderID, model: String) {
        self.answers = answers
        self.provider = provider
        self.model = model
    }

    public subscript(name: String) -> DecisionAnswer? {
        answers.first { $0.name == name }
    }
}

/// Answers a decision request with an ordinary text model: questions go in
/// batches that fit the context window, the model replies with a JSON list,
/// and anything it skipped comes back as a refusal rather than a guess.
public struct DecisionEmulator: Sendable {
    public let provider: any AIProvider

    public init(provider: any AIProvider) {
        self.provider = provider
    }

    static let instructions = """
    You answer questions about a screen recording for a video editor. \
    Answer every question by its name. For a yes/no question give "probability", \
    the chance the answer is yes, from 0 to 1. For a choice question give "choice", \
    one of the listed values. For a score question give "score", the 0-based index \
    of the level that fits, lowest first.
    """

    static let shape = #"[{"name": "q1", "probability": 0.8}, {"name": "q2", "choice": "value"}, {"name": "q3", "score": 2}]"#

    /// Splits questions into batches whose prompt fits `budget` tokens.
    public static func batches(_ questions: [DecisionQuestion], budget: Int) -> [[DecisionQuestion]] {
        var batches: [[DecisionQuestion]] = []
        var current: [DecisionQuestion] = []
        var used = 0
        for question in questions {
            let cost = AITokens.estimate(render(question)) + 8
            if !current.isEmpty, used + cost > budget {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(question)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func render(_ q: DecisionQuestion) -> String {
        switch q.kind {
        case .predicate:
            return "\(q.name) (yes/no): \(q.instructions)"
        case .choice:
            let options = q.choices.map { "\"\($0.value)\" = \($0.description)" }.joined(separator: "; ")
            return "\(q.name) (choice): \(q.instructions) Choices: \(options)"
        case .score:
            let levels = q.levels.enumerated().map { "\($0.offset) = \($0.element.label): \($0.element.description)" }
                .joined(separator: "; ")
            return "\(q.name) (score): \(q.instructions) Levels: \(levels)"
        }
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        // Leave room for the instructions, the shared input and the reply
        // (about 12 tokens an answer).
        let fixed = AITokens.estimate(Self.instructions) + AITokens.estimate(Self.shape) + AITokens.estimate(request.input) + 80
        let room = provider.contextTokens - fixed
        guard room > 200 else { throw AIError.tooLong(provider.id) }
        let budget = room * 2 / 3
        var answers: [DecisionAnswer] = []
        var model = provider.model
        for batch in Self.batches(request.questions, budget: budget) {
            let body = batch.map(Self.render).joined(separator: "\n")
            let text = request.input.isEmpty ? "Questions:\n\(body)" : "\(request.input)\n\nQuestions:\n\(body)"
            let reply = try await provider.complete(AIRequest(
                task: request.task, summary: request.summary,
                instructions: Self.instructions, input: text, format: .json(shape: Self.shape)))
            model = reply.model
            answers += Self.parse(reply.text, questions: batch, provider: provider.id)
        }
        return DecisionResult(answers: answers, provider: provider.id, model: model)
    }

    struct Raw: Decodable {
        var name: String
        var probability: Double?
        var choice: String?
        var score: Double?
    }

    /// Reads the model's JSON list, clamps numbers into range, drops answers
    /// to questions it wasn't asked, and marks missing ones as refused.
    static func parse(_ text: String, questions: [DecisionQuestion], provider: AIProviderID) -> [DecisionAnswer] {
        let raw = (try? AIJSON.decode([Raw].self, from: text)) ?? []
        var byName: [String: Raw] = [:]
        for r in raw where byName[r.name] == nil { byName[r.name] = r }
        return questions.map { q in
            guard let r = byName[q.name] else { return DecisionAnswer(name: q.name, refused: true) }
            switch q.kind {
            case .predicate:
                guard let p = r.probability else { return DecisionAnswer(name: q.name, refused: true) }
                return DecisionAnswer(name: q.name, probability: min(1, max(0, p)))
            case .choice:
                guard let c = r.choice, q.choices.contains(where: { $0.value == c }) else {
                    return DecisionAnswer(name: q.name, refused: true)
                }
                return DecisionAnswer(name: q.name, choice: c)
            case .score:
                guard let s = r.score else { return DecisionAnswer(name: q.name, refused: true) }
                return DecisionAnswer(name: q.name, score: min(Double(max(0, q.levels.count - 1)), max(0, s)))
            }
        }
    }
}

/// Pulls JSON out of a model's reply.
public enum AIJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = Data(extract(text).utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    /// The first complete JSON object or array in `text`, skipping code
    /// fences and prose. Returns `text` trimmed when none is found.
    public static func extract(_ text: String) -> String {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default: break
            }
        }
        return String(chars[start...])
    }
}

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rung 1: Apple Foundation Models, the ~3B model built into macOS 26 with
/// Apple Intelligence. Free, private and offline, but small: a 4,096-token
/// window and good at short jobs (titles, tags, yes/no per sentence), not
/// at reading a whole 10-minute transcript in one go. The ladder skips it
/// for anything that won't fit, and decisions go to it in small batches.
public enum AppleOnDevice {
    /// The on-device provider, or nil when this build or this Mac can't
    /// run it (built without the macOS 26 SDK, or running on macOS 15).
    public static func provider() -> (any AIProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleOnDeviceProvider() }
        #endif
        return nil
    }

    /// What to tell the user on macOS 15 or older builds.
    public static let needsNewerMac = "Needs macOS 26 with Apple Intelligence"
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
public struct AppleOnDeviceProvider: AIProvider {
    public init() {}

    public var id: AIProviderID { .appleOnDevice }
    public var rung: AIRung { .onDevice }
    public var displayName: String { "On this Mac" }
    public var model: String { "apple-foundation-model" }
    public var leavesDevice: Bool { false }
    public var destination: String { "this Mac" }
    public var contextTokens: Int { 4_096 }

    public func availability() async -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("This Mac can't run Apple Intelligence")
            case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in System Settings")
            case .modelNotReady: return .unavailable("Apple Intelligence is still downloading")
            @unknown default: return .unavailable("Apple Intelligence isn't available")
            }
        }
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        let session = LanguageModelSession(instructions: request.fullInstructions)
        do {
            let response = try await session.respond(to: request.input)
            return AIResponse(text: response.content, provider: id, model: model)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw AIError.tooLong(id) }
            if case .guardrailViolation = error { throw AIError.refused(id, "Apple's safety check stopped this one.") }
            throw AIError.badResponse(id, error.localizedDescription)
        }
    }
}
#endif

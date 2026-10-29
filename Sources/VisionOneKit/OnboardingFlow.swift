import Foundation

/// One screen of the first-run flow.
public enum OnboardingStep: Hashable, Sendable {
    case welcome
    case access(AccessKind)
    case finish
}

/// The first-run flow, one thing at a time: a welcome, one step per
/// permission still missing, then a finish. The steps are worked out once
/// when the window opens, so the step count doesn't jump while the user is
/// in System Settings. Returning users skip the welcome and anything
/// already on; with nothing missing they get the plain checklist instead.
///
/// First run leaves Screen Recording out (`askScreen` false): it's asked
/// the first time a screen, window or area recording starts, so a
/// camera-only recording never needs it.
public struct OnboardingFlow: Equatable, Sendable {
    public let steps: [OnboardingStep]
    public let askScreen: Bool

    public init(checklist: AccessChecklist, welcomeSeen: Bool, askScreen: Bool = true) {
        self.askScreen = askScreen
        let kinds = AccessKind.allCases.filter { askScreen || $0 != .screen }
        let needed = kinds.filter { !$0.isOptional }
        if welcomeSeen && needed.allSatisfy({ checklist.state(of: $0) == .granted }) {
            self.steps = []
            return
        }
        var list: [OnboardingStep] = welcomeSeen ? [] : [.welcome]
        for kind in kinds where checklist.state(of: kind) != .granted {
            // The camera is optional: once someone has said no to it, a
            // returning visit doesn't ask again. The checklist still shows it.
            if kind.isOptional && welcomeSeen && checklist.state(of: kind) == .denied { continue }
            list.append(.access(kind))
        }
        list.append(.finish)
        steps = list
    }

    /// Nothing is missing: show the compact checklist, not the steps.
    public var isOverview: Bool { steps.isEmpty }

    /// The finish can offer to record. Without the screen step it always
    /// can: starting a screen recording asks for Screen Recording then.
    public func isReady(_ checklist: AccessChecklist) -> Bool {
        askScreen ? checklist.canRecord : true
    }

    /// The step at `index` is finished. Permission steps are done once
    /// granted (a skipped camera stays not done), the welcome once passed,
    /// and the finish once Vision One can record.
    public func isDone(_ index: Int, current: Int, checklist: AccessChecklist) -> Bool {
        guard steps.indices.contains(index) else { return false }
        switch steps[index] {
        case .welcome: return index < current
        case .access(let kind): return checklist.state(of: kind) == .granted
        case .finish: return isReady(checklist)
        }
    }

    /// The next step after `index` that still needs the user. Permissions
    /// turned on in the meantime are skipped; the finish never is.
    public func next(after index: Int, checklist: AccessChecklist) -> Int? {
        var candidate = index + 1
        while steps.indices.contains(candidate) {
            if case .access(let kind) = steps[candidate], checklist.state(of: kind) == .granted {
                candidate += 1
                continue
            }
            return candidate
        }
        return nil
    }

    /// Where the flow should be now: moves on by itself once the current
    /// permission is granted, so nobody has to press Next after flipping a
    /// switch in System Settings.
    public func advanced(from index: Int, checklist: AccessChecklist) -> Int {
        guard steps.indices.contains(index),
              case .access(let kind) = steps[index],
              checklist.state(of: kind) == .granted
        else { return index }
        return next(after: index, checklist: checklist) ?? index
    }
}

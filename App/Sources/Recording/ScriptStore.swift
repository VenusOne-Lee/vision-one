import Combine
import Foundation
import VisionOneKit

/// The script for the next take. Written by the Home script editor, the
/// coach's "Record for real" or an agent, all through UserDefaults key
/// `script.text`, so any of them can hand a script to the recorder.
@MainActor
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()
    static let textKey = "script.text"
    private static let prompterKey = "script.prompter"

    @Published var text: String {
        didSet { UserDefaults.standard.set(text, forKey: Self.textKey) }
    }
    /// Show the teleprompter when there's a script. On by default.
    @Published var showsPrompter: Bool {
        didSet { UserDefaults.standard.set(showsPrompter, forKey: Self.prompterKey) }
    }

    private init() {
        text = UserDefaults.standard.string(forKey: Self.textKey) ?? ""
        showsPrompter = UserDefaults.standard.object(forKey: Self.prompterKey) as? Bool ?? true
    }

    /// Picks up a script another part of the app saved since launch.
    func reload() {
        let saved = UserDefaults.standard.string(forKey: Self.textKey) ?? ""
        if saved != text { text = saved }
    }

    /// The script for the take about to start, or nil without one.
    var script: Script? {
        let script = Script(text: text)
        return script.isEmpty ? nil : script
    }

    func clear() { text = "" }
}

import AppKit
import SwiftUI
import VisionOneKit

/// Reuses the production native text view between two loaded editors, then
/// invokes its real selection/cut/undo paths without capture or provider access.
@MainActor
enum TranscriptViewVerification {
    private final class Fixture: ObservableObject {
        @Published var editor: EditorModel
        init(_ editor: EditorModel) { self.editor = editor }
    }
    private struct Surface: View {
        @ObservedObject var fixture: Fixture
        var body: some View { TranscriptTextView(model: fixture.editor) }
    }

    private static func textView(in view: NSView) -> TranscriptNSTextView? {
        if let transcript = view as? TranscriptNSTextView { return transcript }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw MediaVerification.Failure(message: message)
    }

    static func run(source: Take, in root: URL) async throws {
        let parent = root.appendingPathComponent("transcript-view-regression")
        let takes = ["A", "B"].map { Take(folder: parent.appendingPathComponent($0)) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for (index, take) in takes.enumerated() {
            if FileManager.default.fileExists(atPath: take.folder.path) { try FileManager.default.removeItem(at: take.folder) }
            try FileManager.default.copyItem(at: source.folder, to: take.folder)
            let words = index == 0 ? ["Alpha", "original."] : ["Bravo", "replacement."]
            try Transcript(language: "en", engine: "take-switch fixture", duration: 3, segments: [.init(words: [
                .init(id: 0, text: words[0], start: 0.2, end: 0.8),
                .init(id: 1, text: words[1], start: 1.6, end: 2.2)
            ])]).write(to: take.transcriptURL)
            try EditList(sourceDuration: 3).write(to: take.editsURL)
        }
        let a = EditorModel(take: takes[0]), b = EditorModel(take: takes[1])
        await a.loadIfNeeded()
        await b.loadIfNeeded()
        defer { a.close(); b.close() }
        try MediaVerification.require(a.phase == .ready && b.phase == .ready, "Transcript switch editors failed to load")
        let originalA = try Data(contentsOf: a.take.editsURL)
        let originalB = b.edits
        let beforeA = a.edits
        let fixture = Fixture(a)
        let host = NSHostingView(rootView: Surface(fixture: fixture).frame(width: 500, height: 400))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await wait("A transcript did not mount") { textView(in: host)?.string.contains("Alpha") == true }
        guard let first = textView(in: host), let selected = first.coordinator?.wordRanges.first else {
            throw MediaVerification.Failure(message: "A native transcript selection missing")
        }
        first.setSelectedRange(selected)
        fixture.editor = b
        try await wait("Transcript coordinator retained A after switching to B") {
            textView(in: host)?.coordinator?.model === b && textView(in: host)?.string.contains("Bravo") == true
        }
        guard let current = textView(in: host), let coordinator = current.coordinator,
              let word = coordinator.wordRanges.first else {
            throw MediaVerification.Failure(message: "B native transcript missing")
        }
        try MediaVerification.require(current.selectedRange().length == 0, "A's selection leaked into B")
        // Exercise the same coordinator entry point used by Delete/context menu.
        current.setSelectedRange(word)
        b.undoManager.beginUndoGrouping()
        coordinator.cutSelection()
        b.undoManager.endUndoGrouping()
        try MediaVerification.require(b.edits != originalB && a.edits == beforeA, "Transcript cut targeted another take")
        b.undoManager.undo()
        try MediaVerification.require(b.edits == originalB, "B transcript cut did not undo")
        b.undoManager.redo()
        try MediaVerification.require(b.edits != originalB, "B transcript cut did not redo")
        try MediaVerification.require(try Data(contentsOf: a.take.editsURL) == originalA, "B transcript action changed A's saved edits")
        fixture.editor = a
        try await wait("Transcript did not return to A") {
            textView(in: host)?.coordinator?.model === a && textView(in: host)?.string.contains("Alpha") == true
        }
        try MediaVerification.require(textView(in: host)?.selectedRange().length == 0, "B's selection leaked back into A")
        try JSONSerialization.data(withJSONObject: ["mountedTakeSwitch": true, "selectionReset": true,
                                                  "currentTakeCutUndoRedo": true, "otherTakeBytesUnchanged": true],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("transcript-view-switch.json"))
        print("Native transcript take-switch/cut/undo/redo verification passed")
    }
}

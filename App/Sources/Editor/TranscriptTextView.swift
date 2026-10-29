import AppKit
import SwiftUI
import VisionOneKit

/// The transcript as one native text view: real selection, keyboard and
/// accessibility, and fast with thousands of words. It is read-only;
/// Delete cuts the selected words instead of editing text.
///
/// Built on TextKit 1 (NSLayoutManager) because it lets us draw the
/// dashed outlines the design uses for proposed cuts and pauses.
struct TranscriptTextView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = DashedLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = TranscriptNSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(Theme.paper)
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Theme.selectionSoft),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor(Theme.selection),
        ]
        textView.setAccessibilityLabel("Transcript")
        textView.coordinator = context.coordinator
        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.bind(model)
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator {
        private(set) var model: EditorModel
        weak var textView: TranscriptNSTextView?
        /// Character range of each word, by word position.
        private(set) var wordRanges: [NSRange] = []
        private var renderedEdits: EditList?
        private var renderedTranscriptRevision = -1
        private var renderedFixes: [VoiceEdits.WordFix]?
        private var underlined: Int?

        init(model: EditorModel) {
            self.model = model
        }

        /// NSViewRepresentable can reuse this coordinator across task switches.
        /// A selection from another take must never cut the previous model.
        func bind(_ next: EditorModel) {
            guard model !== next else { return }
            model = next
            wordRanges = []
            renderedEdits = nil
            renderedTranscriptRevision = -1
            renderedFixes = nil
            underlined = nil
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
        }

        func update() {
            guard let textView, let storage = textView.textStorage else { return }
            if renderedEdits != model.edits || renderedTranscriptRevision != model.transcriptRevision
                || renderedFixes != model.voiceEdits.fixes {
                let selection = textView.selectedRanges
                let (text, ranges) = TranscriptRenderer.render(model: model)
                storage.setAttributedString(text)
                wordRanges = ranges
                renderedEdits = model.edits
                renderedTranscriptRevision = model.transcriptRevision
                renderedFixes = model.voiceEdits.fixes
                underlined = nil
                let kept = selection.filter { $0.rangeValue.upperBound <= storage.length }
                textView.selectedRanges = kept.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : kept
            }
            updatePlayingWord(storage: storage)
        }

        /// Ink underline on the word being spoken. Only touches two words,
        /// so it can run every frame.
        private func updatePlayingWord(storage: NSTextStorage) {
            let playing = model.playingWordIndex
            guard playing != underlined else { return }
            storage.beginEditing()
            if let old = underlined, old < wordRanges.count {
                storage.removeAttribute(.underlineStyle, range: wordRanges[old])
            }
            if let new = playing, new < wordRanges.count {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NSColor(Theme.text),
                ], range: wordRanges[new])
                if model.isPlaying { textView?.scrollRangeToVisible(wordRanges[new]) }
            }
            storage.endEditing()
            underlined = playing
        }

        /// Word positions covered by the selection, or nil when it holds
        /// no words (only a pause chip, say).
        func selectedWords() -> ClosedRange<Int>? {
            guard let selection = textView?.selectedRange(), selection.length > 0 else { return nil }
            let hits = wordRanges.indices.filter { NSIntersectionRange(wordRanges[$0], selection).length > 0 }
            guard let first = hits.first, let last = hits.last else { return nil }
            return first...last
        }

        func word(atCharacter index: Int) -> Int? {
            wordRanges.firstIndex { NSLocationInRange(index, $0) }
        }

        // Actions from the text view.

        func cutSelection() {
            guard let range = selectedWords() else { NSSound.beep(); return }
            model.toggleCut(words: range)
        }

        /// The suggested cut over the word at `index`, if it's dashed.
        func proposedCut(atCharacter index: Int) -> Cut? {
            guard let word = word(atCharacter: index), word < model.wordSpans.count else { return nil }
            let span = model.wordSpans[word]
            return model.proposedCut(at: (span.start + span.end) / 2)
        }

        func decide(_ id: UUID, accept: Bool) {
            model.decide(id, accept: accept)
        }

        /// Opens the Redo card for the sentence holding the word at `index`.
        func redoSentence(atCharacter index: Int) {
            guard let word = word(atCharacter: index), word < model.wordSpans.count else { return }
            let span = model.wordSpans[word]
            let sentences = model.transcript?.sentences(keeping: model.edits) ?? []
            model.redoTarget = SpokenEdit.sentence(at: (span.start + span.end) / 2, in: sentences, lookBack: 0)
        }

        func clicked(character index: Int) {
            guard let word = word(atCharacter: index), word < model.wordSpans.count else { return }
            model.seek(toSource: model.wordSpans[word].start)
        }
    }
}

/// Builds the attributed transcript: one paragraph per segment, cut words
/// grey and struck through, proposed cuts dashed, long pauses as mono
/// duration chips.
@MainActor
enum TranscriptRenderer {
    static let minimumPause = 0.6

    static func render(model: EditorModel) -> (NSAttributedString, [NSRange]) {
        let text = NSMutableAttributedString()
        var ranges: [NSRange] = []
        guard let transcript = model.transcript else { return (text, ranges) }
        let marks = model.wordMarks

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.5
        paragraph.paragraphSpacing = 14
        let serif = Theme.transcriptFont(size: 17)
        let base: [NSAttributedString.Key: Any] = [
            .font: serif,
            .foregroundColor: NSColor(Theme.text),
            .paragraphStyle: paragraph,
        ]
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        // Words re-said in an AI copy of the voice, always labelled.
        let fixes = Dictionary(model.voiceEdits.fixes.map { ($0.wordID, $0) }, uniquingKeysWith: { _, last in last })

        var index = 0
        var previousEnd: Double?
        for (s, segment) in transcript.segments.enumerated() {
            if s > 0 { text.append(NSAttributedString(string: "\n", attributes: base)) }
            // Paragraph timecode.
            text.append(NSAttributedString(string: Timecode.string(from: segment.start) + "\n", attributes: [
                .font: mono, .foregroundColor: NSColor(Theme.textMuted), .paragraphStyle: paragraph,
            ]))
            for word in segment.words {
                if let previousEnd, word.start - previousEnd >= minimumPause {
                    let pause = TimeSpan(start: previousEnd, end: word.start)
                    let cut = model.edits.isRemoved((pause.start + pause.end) / 2)
                    var attributes = base
                    attributes[.font] = mono
                    attributes[.foregroundColor] = NSColor(cut ? Theme.cutText : Theme.textMuted)
                    attributes[.dashedOutline] = DashedOutline.pause.rawValue
                    if cut { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    text.append(NSAttributedString(string: String(format: "%.1fs", pause.duration), attributes: attributes))
                    text.append(NSAttributedString(string: " ", attributes: base))
                }
                var attributes = base
                switch index < marks.count ? marks[index] : .kept {
                case .kept:
                    break
                case .cut:
                    attributes[.foregroundColor] = NSColor(Theme.cutText)
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case let .proposed(reason):
                    if reason == Cut.Reason.filler {
                        attributes[.backgroundColor] = NSColor(Theme.fillerBackground)
                        attributes[.foregroundColor] = NSColor(Theme.fillerText)
                        attributes[.dashedOutline] = DashedOutline.filler.rawValue
                    } else {
                        attributes[.dashedOutline] = DashedOutline.proposed.rawValue
                    }
                }
                let fix = fixes[word.id]
                if let fix, attributes[.dashedOutline] == nil, attributes[.strikethroughStyle] == nil {
                    // Dashed while proposed, solid once kept.
                    attributes[.dashedOutline] = (fix.kept ? DashedOutline.aiVoiceKept : .proposed).rawValue
                }
                let start = text.length
                let shown = fix.map { $0.replacement.isEmpty ? word.text : $0.replacement } ?? word.text
                text.append(NSAttributedString(string: shown, attributes: attributes))
                ranges.append(NSRange(location: start, length: text.length - start))
                if let fix {
                    text.append(NSAttributedString(string: "\u{2009}AI voice", attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                        .foregroundColor: NSColor(Theme.textMuted),
                        .baselineOffset: 6,
                        .paragraphStyle: paragraph,
                        .toolTip: fix.kept
                            ? "Re-said by an AI copy of your voice (was “\(fix.original)”). Export says so."
                            : "Proposed: re-said by an AI copy of your voice (was “\(fix.original)”). Keep or undo it in Voice Tools.",
                    ]))
                }
                text.append(NSAttributedString(string: " ", attributes: base))
                previousEnd = word.end
                index += 1
            }
        }
        return (text, ranges)
    }
}

extension NSAttributedString.Key {
    /// Draws a dashed rounded outline around the run: the design's mark
    /// for "proposed, not done yet".
    static let dashedOutline = NSAttributedString.Key("VisionOneDashedOutline")
}

enum DashedOutline: Int {
    case filler, proposed, pause
    /// A kept AI word fix: the same outline, solid.
    case aiVoiceKept
}

/// Draws the dashed outlines after the normal background.
final class DashedLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.dashedOutline, in: characters) { value, range, _ in
            guard let raw = value as? Int, let kind = DashedOutline(rawValue: raw) else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let color: NSColor = kind == .filler ? NSColor(Theme.ringGold) : NSColor(Theme.textMuted)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 1)
                let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
                path.lineWidth = 1
                if kind != .aiVoiceKept { path.setLineDash([3, 2], count: 2, phase: 0) }
                (kind == .aiVoiceKept ? NSColor(Theme.text) : color).setStroke()
                path.stroke()
            }
        }
    }
}

/// Keys: Delete cuts or restores the selection, Space plays, J K L
/// shuttle, ⌘Z undoes. A plain click moves the playhead to the word;
/// right-clicking a dashed word cuts or keeps that suggestion.
final class TranscriptNSTextView: NSTextView {
    weak var coordinator: TranscriptTextView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let model = coordinator.model
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "z" {
            model.undoManager.undo()
        } else if flags == [.command, .shift], key == "z" {
            model.undoManager.redo()
        } else if !flags.isDisjoint(with: [.command, .control, .option]) {
            super.keyDown(with: event)
        } else if event.keyCode == 51 || event.keyCode == 117 { // Delete, forward delete
            coordinator.cutSelection()
        } else if event.keyCode == 49 { // Space
            model.togglePlay()
        } else if key == "j" {
            model.skip(by: -5)
        } else if key == "k" {
            model.pause()
        } else if key == "l" {
            model.play()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event) // tracks the drag until mouse up
        guard selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        coordinator?.clicked(character: index)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let index = characterIndex(at: event), let cut = coordinator?.proposedCut(atCharacter: index) {
            let accept = NSMenuItem(title: "Cut these words", action: #selector(acceptSuggestion(_:)), keyEquivalent: "")
            accept.representedObject = cut.id
            accept.target = self
            menu.addItem(accept)
            let reject = NSMenuItem(title: "Keep these words", action: #selector(rejectSuggestion(_:)), keyEquivalent: "")
            reject.representedObject = cut.id
            reject.target = self
            menu.addItem(reject)
            menu.addItem(.separator())
        }
        let item = NSMenuItem(title: "Cut from Video / Restore", action: #selector(cutFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        if let index = characterIndex(at: event) {
            let redo = NSMenuItem(title: "Redo This Sentence…", action: #selector(redoFromMenu(_:)), keyEquivalent: "")
            redo.representedObject = index
            redo.target = self
            menu.addItem(redo)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func redoFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        coordinator?.redoSentence(atCharacter: index)
    }

    @objc private func cutFromMenu() {
        coordinator?.cutSelection()
    }

    @objc private func acceptSuggestion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator?.decide(id, accept: true)
    }

    @objc private func rejectSuggestion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator?.decide(id, accept: false)
    }

    /// The character under the pointer, not the nearest insertion point,
    /// so the right half of a word still counts as that word.
    private func characterIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return layoutManager.characterIndex(for: inContainer, in: textContainer,
                                            fractionOfDistanceBetweenInsertionPoints: nil)
    }
}

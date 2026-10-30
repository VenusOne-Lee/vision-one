import AppKit
import SwiftUI
import VisionOneKit

/// Exercises the production Harness window and Edit action target, rather
/// than the transcript's private key handler or toolbar's direct undo call.
@MainActor
enum WorkspaceUndoVerification {
    private static func key(in window: NSWindow, redo: Bool) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: redo ? [.command, .shift] : .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: redo ? "Z" : "z", charactersIgnoringModifiers: redo ? "Z" : "z",
            isARepeat: false, keyCode: 6) else {
            throw MediaVerification.Failure(message: "Couldn't make workspace undo key")
        }
        return event
    }

    static func run(source: Take, in root: URL) async throws {
        let parent = root.appendingPathComponent("workspace-undo-regression")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let takes = ["A", "B"].map { Take(folder: parent.appendingPathComponent($0)) }
        for take in takes {
            if FileManager.default.fileExists(atPath: take.folder.path) { try FileManager.default.removeItem(at: take.folder) }
            try FileManager.default.copyItem(at: source.folder, to: take.folder)
            try EditList(sourceDuration: 3).write(to: take.editsURL)
        }
        let project = DeskProject(name: "Undo verification")
        let a = DeskTask(projectID: project.id, title: "A", takes: [takes[0]])
        let b = DeskTask(projectID: project.id, title: "B", takes: [takes[1]])
        let model = HarnessModel(snapshot: DeskSnapshot(projects: [project], tasks: [a, b]),
                                 takes: takes, page: .task(a.id))
        model.mode = .editor
        await model.workspace?.load()
        guard let first = model.workspace?.editor else { throw MediaVerification.Failure(message: "A editor missing") }
        let priorPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        if !NSApp.isRunning { NSApp.finishLaunching() }
        defer { NSApp.setActivationPolicy(priorPolicy) }
        let controller = EditorWindowController(model: model)
        controller.present()
        guard let window = controller.window else { throw MediaVerification.Failure(message: "Harness window missing") }
        defer { window.close() }
        // The workspace CLI runs NSApplication; wait for WindowServer activation before testing
        // the real key-window responder chain. Never skip the focus assertion.
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window { break }
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(50))
        }
        try MediaVerification.require(NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window,
                                      "Harness undo fixture is not active/key after bounded activation")
        window.makeFirstResponder(nil)

        let actions = WorkspaceUndoActions.shared
        let menu = NSMenu(title: "Edit verification")
        menu.autoenablesItems = false
        let undo = NSMenuItem(title: "Undo", action: #selector(WorkspaceUndoActions.undo(_:)), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = .command
        undo.target = actions
        let redo = NSMenuItem(title: "Redo", action: #selector(WorkspaceUndoActions.redo(_:)), keyEquivalent: "Z")
        // AppKit treats uppercase Z + Command as Command-Shift-z. Match
        // the shifted event character rather than dispatching Undo again.
        // https://developer.apple.com/documentation/appkit/nsmenuitem/keyequivalentmodifiermask
        redo.keyEquivalentModifierMask = .command
        redo.target = actions
        menu.addItem(undo); menu.addItem(redo)

        first.undoManager.beginUndoGrouping()
        first.trimEnd(to: 2.5)
        first.undoManager.endUndoGrouping()
        actions.refresh()
        try MediaVerification.require(actions.canUndo && actions.undoTitle == "Undo Trim End", "Workspace Edit state missed trim")
        try MediaVerification.require(menu.performKeyEquivalent(with: try key(in: window, redo: false)), "Canvas Cmd-Z was not dispatched")
        try MediaVerification.require(abs(first.edits.outputDuration - 3) < 0.001 && actions.canRedo, "Canvas Cmd-Z did not undo trim")
        try MediaVerification.require(menu.performKeyEquivalent(with: try key(in: window, redo: true)), "Canvas redo key was not dispatched")
        try MediaVerification.require(abs(first.edits.outputDuration - 2.5) < 0.001, "Canvas Cmd-Shift-Z did not redo trim")

        // Effects mutate their own ObservableObject. Editor-owned toolbar
        // controls must also refresh at group close, Undo and Redo.
        var editorInvalidations = 0
        let undoRefresh = first.objectWillChange.sink { editorInvalidations += 1 }
        defer { undoRefresh.cancel() }
        let originalZooms = first.effects.zooms
        first.undoManager.beginUndoGrouping()
        first.effects.addZoom(at: 0, sourceDuration: first.edits.sourceDuration)
        let afterEffect = editorInvalidations
        first.undoManager.endUndoGrouping()
        let addedZooms = first.effects.zooms
        try MediaVerification.require(addedZooms != originalZooms && first.undoManager.canUndo
            && editorInvalidations > afterEffect, "Effect group close did not refresh editor Undo controls")
        let beforeUndo = editorInvalidations
        first.undoManager.undo()
        try MediaVerification.require(first.effects.zooms == originalZooms && first.undoManager.canRedo
            && editorInvalidations > beforeUndo, "Effect Undo did not refresh editor Redo controls")
        let beforeRedo = editorInvalidations
        first.undoManager.redo()
        try MediaVerification.require(first.effects.zooms == addedZooms && first.undoManager.canUndo
            && editorInvalidations > beforeRedo, "Effect Redo did not refresh editor Undo controls")
        first.undoManager.undo()
        first.effects.isAdjusting = false

        model.page = .task(b.id)
        await model.workspace?.load()
        guard let second = model.workspace?.editor else { throw MediaVerification.Failure(message: "B editor missing") }
        window.makeFirstResponder(nil)
        second.undoManager.beginUndoGrouping()
        second.trimEnd(to: 2)
        second.undoManager.endUndoGrouping()
        actions.refresh()
        try MediaVerification.require(WorkspaceUndoActions.manager(in: window) === second.undoManager,
                                      "Undo routing retained A after task switch")
        _ = menu.performKeyEquivalent(with: try key(in: window, redo: false))
        try MediaVerification.require(abs(second.edits.outputDuration - 3) < 0.001 && abs(first.edits.outputDuration - 2.5) < 0.001,
                                      "B undo changed A or failed to undo B")
        _ = menu.performKeyEquivalent(with: try key(in: window, redo: true))

        // Standard field-editor typing must retain its own active undo context.
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 28))
        field.stringValue = "Draft"
        window.contentView?.addSubview(field)
        field.selectText(nil)
        guard let text = window.firstResponder as? NSTextView, text.isFieldEditor, let typingUndo = text.undoManager else {
            throw MediaVerification.Failure(message: "Native field editor did not acquire undo")
        }
        let beforeA = first.edits, beforeB = second.edits
        typingUndo.beginUndoGrouping()
        text.insertText(" extra", replacementRange: NSRange(location: 5, length: 0))
        typingUndo.endUndoGrouping()
        actions.refresh()
        try MediaVerification.require(WorkspaceUndoActions.manager(in: window) === typingUndo, "Typing lost its native undo owner")
        _ = menu.performKeyEquivalent(with: try key(in: window, redo: false))
        try MediaVerification.require(text.string == "Draft" && first.edits == beforeA && second.edits == beforeB,
                                      "Text-field undo consumed a video edit")
        _ = menu.performKeyEquivalent(with: try key(in: window, redo: true))
        try MediaVerification.require(text.string == "Draft extra", "Text-field redo failed")
        window.makeFirstResponder(nil)
        field.removeFromSuperview()

        try JSONSerialization.data(withJSONObject: ["effectUndoControlsRefresh": true, "canvasTrimUndoRedo": true, "taskSwitchRoutesCurrentEditor": true,
                                                  "textFieldUndoRedoPreserved": true],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("workspace-undo.json"))
        print("Native Harness canvas/menu-key undo/redo, task switching and text-field undo verification passed")
    }
}

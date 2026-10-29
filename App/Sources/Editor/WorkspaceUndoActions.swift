import AppKit
import Combine

/// One context for the Edit menu and its shortcuts. Resolve it at invocation,
/// because a task switch or an active field editor can change the undo owner.
@MainActor
final class WorkspaceUndoActions: NSObject, ObservableObject {
    static let shared = WorkspaceUndoActions()
    @Published private(set) var undoTitle = "Undo"
    @Published private(set) var redoTitle = "Redo"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var tokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didUpdateNotification,
            Notification.Name.NSUndoManagerDidCloseUndoGroup, Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange, NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification, NSText.didChangeNotification
        ]
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    static func manager(in window: NSWindow?) -> UndoManager? {
        guard let window else { return nil }
        if let text = window.firstResponder as? NSTextView, text.isEditable || text.isFieldEditor {
            // Never consume the editor history while a text control owns focus.
            return text.undoManager
        }
        if let controller = window.delegate as? EditorWindowController {
            return controller.workspaceUndoManager
        }
        return window.undoManager
    }

    func refresh() {
        let manager = Self.manager(in: NSApp.keyWindow)
        let undo = manager?.canUndo == true, redo = manager?.canRedo == true
        let undoName = manager?.undoActionName ?? "", redoName = manager?.redoActionName ?? ""
        let undoLabel = undo && !undoName.isEmpty ? "Undo \(undoName)" : "Undo"
        let redoLabel = redo && !redoName.isEmpty ? "Redo \(redoName)" : "Redo"
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
        if undoTitle != undoLabel { undoTitle = undoLabel }
        if redoTitle != redoLabel { redoTitle = redoLabel }
    }

    @objc func undo(_ sender: Any?) {
        if let manager = Self.manager(in: NSApp.keyWindow), manager.canUndo { manager.undo() }
        refresh()
    }

    @objc func redo(_ sender: Any?) {
        if let manager = Self.manager(in: NSApp.keyWindow), manager.canRedo { manager.redo() }
        refresh()
    }
}

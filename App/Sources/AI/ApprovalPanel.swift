import AppKit
import SwiftUI
import VisionOneKit

/// Where an approval is asked, so the user answers it once. A request on
/// a Desk task waits on the task's numbered card; the floating panel asks
/// too only when the main window is closed, hidden or behind another app
/// (`ApprovalSurface`). Both answer the same pending approval on the job
/// board, so answering one clears the other.
enum ApprovalPlacement {
    /// Whether the floating panel asks for an approval on `jobID`.
    static func panelAsks(jobID: UUID, desk: Desk) async -> Bool {
        let onTask = await desk.taskID(forJob: jobID) != nil
        let inFront = await MainActor.run { MainWindowPresence.inFront }
        return ApprovalSurface.route(onTask: onTask, windowInFront: inFront).showsPanel
    }
}

/// Whether the main (harness) window is where the user is looking: on
/// screen, not minimised or covered, and Vision One the app in front.
@MainActor
enum MainWindowPresence {
    /// `EditorWindowController` gives the main window this autosave name.
    private static let autosaveName = "VisionOneEditor"

    static var inFront: Bool {
        guard NSApp.isActive, !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            window.frameAutosaveName == autosaveName
                && window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }
}

/// Shows the approval sheet for anything about to leave the Mac, one at a
/// time, and hands the answer back to the gate. A floating panel rather
/// than a sheet, because a menu bar app may have no window open. For a
/// job's request it only shows when the task's card is out of view, and
/// goes away when the card is answered (`dismiss`).
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    private struct Pending {
        let request: OutboundRequest
        let reply: CheckedContinuation<OutboundDecision, Never>
    }

    @Published private(set) var current: OutboundRequest?
    private var queue: [Pending] = []
    private var active: Pending?
    private var panel: NSPanel?

    func ask(_ request: OutboundRequest) async -> OutboundDecision {
        // Already answered on the task before the panel got its turn.
        if Task.isCancelled { return .deny }
        return await withCheckedContinuation { continuation in
            queue.append(Pending(request: request, reply: continuation))
            showNext()
        }
    }

    func answer(_ decision: OutboundDecision) {
        active?.reply.resume(returning: decision)
        active = nil
        current = nil
        if queue.isEmpty { panel?.orderOut(nil) }
        showNext()
    }

    /// The user answered on the task's card instead: take this request
    /// off the panel. The "no" it hands back is ignored by the board.
    func dismiss(_ requestID: UUID) {
        if active?.request.id == requestID {
            answer(.deny)
        } else if let i = queue.firstIndex(where: { $0.request.id == requestID }) {
            queue.remove(at: i).reply.resume(returning: .deny)
        }
    }

    private func showNext() {
        guard active == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        active = next
        current = next.request
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            // Keep the sheet out of the recording, like every Vision One window.
            panel.sharingType = .none
            panel.contentViewController = NSHostingController(rootView: ApprovalView(center: self))
            panel.standardWindowButton(.closeButton)?.isHidden = true
            self.panel = panel
        }
        panel?.center()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }
}

struct ApprovalView: View {
    @ObservedObject var center: ApprovalCenter

    var body: some View {
        Group {
            if let request = center.current {
                content(request)
            } else {
                Color.clear.frame(width: 420, height: 10)
            }
        }
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .themed()
    }

    private func content(_ r: OutboundRequest) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.kind == .post ? "Post to \(r.providerName)?" : "Send to \(r.providerName)?")
                    .font(.system(size: 17, weight: .bold))
                Text(r.summary)
                    .font(.system(size: 13, weight: .medium))
                Text(r.kind == .post
                     ? "This publishes the text below. You can't unsend it."
                     : r.kind == .audio
                     ? "This sends your voice, as described below. Never your screen."
                     : "This sends the words below, not the video or audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            ScrollView {
                Text(r.preview + (r.characters > r.preview.count ? "…" : ""))
                    .font(.system(size: 12, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 110)
            .padding(10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { label("To"); Text(r.destination).font(.system(size: 12, design: .monospaced)) }
                if r.kind != .audio {
                    GridRow { label("Size"); Text("\(r.characters.formatted()) characters").font(.system(size: 12, design: .monospaced)) }
                }
                if r.kind != .post {
                    GridRow { label("Cost"); Text(cost(r)).font(.system(size: 12, design: .monospaced)) }
                }
            }
            HStack {
                Button(r.kind == .post ? "Don't post" : "Don't send") { center.answer(.deny) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if r.kind != .post {
                    Button("Allow for this session") { center.answer(.allowForSession) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .help("Don't ask again for this job and provider until Vision One quits")
                }
                Button(r.kind == .post ? "Post" : "Send once") { center.answer(.allowOnce) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 420)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
    }

    private func cost(_ r: OutboundRequest) -> String {
        if r.fromPlan { return "R0 · from your ChatGPT plan" }
        if r.provider == .elevenLabs { return "From your ElevenLabs credits" }
        guard let rand = r.estimatedRand else { return "Unknown · your key's price" }
        return rand < 0.01 ? "under R0.01" : String(format: "about R%.2f", rand)
    }
}

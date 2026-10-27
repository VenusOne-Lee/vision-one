import AppKit
import SwiftUI
import VisionOneKit

/// Shows the approval sheet for anything about to leave the Mac, one at a
/// time, and hands the answer back to the gate. A floating panel rather
/// than a sheet, because a menu bar app may have no window open.
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
        await withCheckedContinuation { continuation in
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
            panel.appearance = NSAppearance(named: .aqua)
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
        .environment(\.colorScheme, .light)
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
                     : "This sends the words of this take, not the video or audio.")
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
                GridRow { label("Size"); Text("\(r.characters.formatted()) characters").font(.system(size: 12, design: .monospaced)) }
                if r.kind == .aiRequest {
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
                if r.kind == .aiRequest {
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
        guard let rand = r.estimatedRand else { return "Unknown · your key's price" }
        return rand < 0.01 ? "under R0.01" : String(format: "about R%.2f", rand)
    }
}

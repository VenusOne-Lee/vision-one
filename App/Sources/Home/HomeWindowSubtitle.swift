import AppKit
import SwiftUI

/// Puts a muted line under the window title ("3 takes this week"). The
/// window is an AppKit NSWindow hosting SwiftUI, so navigationSubtitle
/// doesn't reach it; this sets `NSWindow.subtitle` directly.
struct HomeWindowSubtitle: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        let text = self.text
        // The view has no window until it's on screen.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, window.subtitle != text else { return }
            window.subtitle = text
        }
    }
}

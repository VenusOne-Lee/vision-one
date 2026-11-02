import AppKit
import SwiftUI
import VisionOneKit

/// One Settings window for Appearance, Brand, AI and Access, instead of a window
/// each. Ink pills along the top pick the pane; the window remembers its
/// size and the last pane.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, brand, ai, agents, access

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .brand: return "Brand"
        case .ai: return "AI"
        case .agents: return "Agents"
        case .access: return "Access"
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane {
        didSet {
            UserDefaults.standard.set(pane.rawValue, forKey: "settings.pane")
            if pane == .access { AccessCenter.shared.startWatching() }
        }
    }

    init() {
        pane = UserDefaults.standard.string(forKey: "settings.pane").flatMap(SettingsPane.init(rawValue:)) ?? .brand
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(SettingsPane.allCases) { pane in
                    Button(pane.title) { model.pane = pane }
                        .buttonStyle(PillButtonStyle(kind: model.pane == pane ? .primary : .secondary))
                        .accessibilityAddTraits(model.pane == pane ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                switch model.pane {
                case .appearance:
                    AppearanceSettingsView(store: ThemeStore.shared)
                case .brand:
                    BrandSettingsView(store: BrandStore.shared)
                case .ai:
                    AISettingsView()
                case .agents:
                    AgentsSettingsView(service: MCPService.shared)
                case .access:
                    ScrollView {
                        VStack(spacing: Theme.Space.md) {
                            AutopilotAccessibilityPanel().padding(Theme.Space.md)
                            SetupView(access: AccessCenter.shared).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .themed()
    }
}

/// Owns the Settings window, made on demand.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let model = SettingsModel()
    private var window: NSWindow?

    func show(_ pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }
        if model.pane == .access { AccessCenter.shared.startWatching() }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            // AI keys are typed here; keep them out of recordings.
            window.sharingType = .none
            window.delegate = self
            window.setFrameAutosaveName("VisionOneSettings")
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { AccessCenter.shared.stopWatching() }
    }
}

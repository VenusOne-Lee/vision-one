import AppKit
import SwiftUI
import VisionOneKit
import WebKit

/// Settings · Brand. The form on the left, a live preview on the right;
/// the divider drags, the window resizes, and the corner logo is placed
/// by dragging it on the preview.
struct BrandSettingsView: View {
    @ObservedObject var store: BrandStore
    @State private var preview: Preview = .intro

    enum Preview: String, CaseIterable, Identifiable {
        case intro = "Intro", during = "During", outro = "Outro"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            ScrollView {
                form
                    .padding(Theme.Space.lg)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            .background(Theme.paper)

            previewPane
                .padding(Theme.Space.lg)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .frame(minWidth: 720, minHeight: 480)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Brand")
                    .font(.system(size: 26, weight: .light))
                Text("Set it once. Every template reads it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }

            if let problem = store.problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                    .padding(Theme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.errorSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }

            field("Ring") { RingPicker(selection: $store.kit.ring) }

            field("Logo") {
                HStack(spacing: Theme.Space.sm) {
                    LogoBadge(image: store.logoImage, initial: store.kit.initial, ring: store.kit.ring)
                        .frame(width: 32, height: 32)
                    Button(store.logoImage == nil ? "Choose…" : "Change…") { store.chooseLogo() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    if store.logoImage != nil {
                        Button("Remove") { store.removeLogo() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }

            field("Name") { TextField("Ledger Lite", text: $store.kit.name) }
            field("Tagline") { TextField("Invoices for Mzansi freelancers", text: $store.kit.tagline) }
            field("Site") { TextField("ledgerlite.co.za", text: $store.kit.site) }
            field("Call to action") { TextField("Try it on Version One", text: $store.kit.cta) }
            field("Fonts") {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    TextField("Display font", text: $store.kit.fonts.display)
                    TextField("Body font", text: $store.kit.fonts.body)
                }
            }

            Divider().overlay(Theme.line)

            CardRow(title: "Intro card", card: $store.kit.intro)
            CardRow(title: "Outro card", card: $store.kit.outro)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Toggle("Logo in the corner", isOn: $store.kit.watermark.enabled)
                    .toggleStyle(.switch)
                    .tint(Theme.text)
                    .font(.system(size: 13))
                if store.kit.watermark.enabled {
                    HStack {
                        Text("Size").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        Slider(value: $store.kit.watermark.size, in: 0.04...0.25)
                            .tint(Theme.text)
                    }
                    Text(store.logoImage == nil
                         ? "Add a logo to show it in the corner."
                         : "Drag it on the preview to place it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
            }

            Text("Saved as brand.json in your Vision One folder, with your logo beside it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            content()
        }
    }

    // MARK: - Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Picker("Preview", selection: $preview) {
                ForEach(Preview.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            Group {
                switch preview {
                case .intro: cardPreview(.intro, card: store.kit.intro)
                case .outro: cardPreview(.outro, card: store.kit.outro)
                case .during: DuringPreview(store: store)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line))

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func cardPreview(_ kind: NativeCard.Kind, card: BrandCard) -> some View {
        if card.enabled {
            CardPreview(kind: kind, variables: store.cardVariables)
        } else {
            ZStack {
                Theme.paper
                Text(kind == .intro ? "No intro: the video starts on your first word." : "No outro: the video ends on your last word.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }
}

/// Seven ring colours from Version One. Picked = filled.
private struct RingPicker: View {
    @Binding var selection: RingColour

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(RingColour.allCases) { ring in
                let colour = Color(hex: ring.hex)
                Button {
                    selection = ring
                } label: {
                    Circle()
                        .strokeBorder(colour, lineWidth: 3)
                        .background(Circle().fill(selection == ring ? colour : Theme.paper))
                        .frame(width: 22, height: 22)
                        .padding(2)
                        .overlay(Circle().strokeBorder(selection == ring ? Theme.text : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(ring.title)
                .accessibilityLabel("\(ring.title) ring")
                .accessibilityAddTraits(selection == ring ? .isSelected : [])
            }
        }
    }
}

/// On or off, and how long it stays on screen.
private struct CardRow: View {
    let title: String
    @Binding var card: BrandCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Toggle(title, isOn: $card.enabled)
                .toggleStyle(.switch)
                .tint(Theme.text)
                .font(.system(size: 13))
            if card.enabled {
                HStack {
                    Slider(value: $card.duration, in: BrandCard.durationRange, step: 0.5)
                        .tint(Theme.text)
                    Text(String(format: "%.1f s", card.clampedDuration))
                        .font(.system(size: 11, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

/// The logo, or the name's first letter in the ring.
private struct LogoBadge: View {
    let image: NSImage?
    let initial: String
    let ring: RingColour

    var body: some View {
        ZStack {
            Circle().fill(Theme.paper)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Text(initial).font(.system(size: 13, weight: .heavy))
            }
            Circle().strokeBorder(Color(hex: ring.hex), lineWidth: 3)
        }
    }
}

/// A recording stand-in with the corner logo, which drags anywhere.
private struct DuringPreview: View {
    @ObservedObject var store: BrandStore

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let mark = store.kit.watermark
            let width = min(size.width, size.height) * mark.size
            ZStack(alignment: .topLeading) {
                ScreenStandIn()
                if mark.enabled, let image = store.logoImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: width)
                        .opacity(mark.opacity)
                        .position(x: size.width * mark.centerX, y: size.height * mark.centerY)
                        .gesture(DragGesture().onChanged { value in
                            store.kit.watermark.centerX = min(max(value.location.x / max(size.width, 1), 0), 1)
                            store.kit.watermark.centerY = min(max(value.location.y / max(size.height, 1), 0), 1)
                        })
                        .help("Drag to place your logo")
                }
            }
        }
    }
}

private struct ScreenStandIn: View {
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Theme.canvas.frame(width: geometry.size.width * 0.22)
                VStack(alignment: .leading, spacing: geometry.size.height * 0.06) {
                    ForEach([0.6, 0.9, 0.8, 0.45, 0.7], id: \.self) { share in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.line)
                            .frame(width: geometry.size.width * 0.66 * share, height: geometry.size.height * 0.06)
                    }
                }
                .padding(.leading, geometry.size.width * 0.05)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .background(Theme.paper)
        }
    }
}

/// The real HTML card in a web view, playing its animation, so the
/// preview is what export draws.
private struct CardPreview: NSViewRepresentable {
    let kind: NativeCard.Kind
    let variables: CardVariables

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.show(kind, variables, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.show(kind, variables, in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var shown: (kind: NativeCard.Kind, variables: CardVariables)?

        /// Reloads when anything changed, so the animation plays again
        /// with the new values.
        @MainActor
        func show(_ kind: NativeCard.Kind, _ variables: CardVariables, in view: WKWebView) {
            if let shown, shown.kind == kind, shown.variables == variables { return }
            shown = (kind, variables)
            guard let url = Bundle.main.url(forResource: kind == .intro ? "brand-intro" : "brand-outro",
                                            withExtension: "html") else { return }
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                guard let variables = shown?.variables else { return }
                webView.callAsyncJavaScript(CardScript.prepare, arguments: [
                    "text": variables.text,
                    "css": variables.css,
                    "logo": variables.logoDataURL ?? NSNull(),
                ], in: nil, in: .page, completionHandler: nil)
            }
        }
    }
}

/// Owns the Brand window, made on demand like the setup window.
@MainActor
final class BrandWindowController: NSObject {
    static let shared = BrandWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Brand"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: BrandSettingsView(store: BrandStore.shared))
            window.appearance = NSAppearance(named: .aqua)
            window.setFrameAutosaveName("VisionOneBrandWindow")
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

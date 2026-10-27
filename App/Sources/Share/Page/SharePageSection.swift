import AppKit
import SwiftUI
import VisionOneKit

/// "Share page" in the Post panel: pick a look, publish, copy the link.
/// One button does the right thing: with Cloudflare connected it puts
/// the page online; without, it makes a folder to put anywhere. The rest
/// (colours, layout, what viewers can do) sits under "Customise".
struct SharePageSection: View {
    @StateObject private var model: SharePageModel
    @ObservedObject private var cloudflare = CloudflareConnection.shared
    @State private var customising = false
    @State private var connecting = false
    @State private var copied = false

    init(take: Take) {
        _model = StateObject(wrappedValue: SharePageModel(take: take))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("SHARE PAGE")
                .textStyle(.caption)
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, Theme.Space.xs)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(model.isPublished && model.record.host == .cloudflare
                     ? "Viewers can ask the video, react and leave you notes."
                     : "A page with the video and its transcript. Viewers can ask it questions.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                LookPicker(selected: model.record.look.preset) { model.applyPreset($0) }
                if customising { Customise(model: model) }
                status
                actions
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .statusOutline(model.isPublished ? .accepted : .proposed, cornerRadius: Theme.Radius.lg)
            if model.isPublished, model.record.host == .cloudflare {
                ViewersPanel(model: model)
            }
        }
        .sheet(isPresented: $connecting) { ConnectCloudflareSheet() }
        .task { await model.pull() }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .working(let what):
            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                Text(what).textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
        case .failed(let message):
            Notice(.error, lead: "The page didn't publish", detail: message,
                   action: (title: "OK", run: { model.clearError() }))
        case .idle:
            if let link = model.link {
                HStack(spacing: Theme.Space.sm) {
                    Mono(link.absoluteString.replacingOccurrences(of: "https://", with: ""), small: true)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button(copied ? "Copied" : "Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        copied = true
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                }
            } else if model.isPublished {
                Text("Made a folder. Put it on any website, or connect Cloudflare for a link with notes and insights.")
                    .textStyle(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(publishTitle) { Task { await model.publish() } }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                .disabled(model.isBusy)
                .help(model.hasExport ? "" : "Export the video first")
            Button(customising ? "Done" : "Customise") { customising.toggle() }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            Spacer(minLength: 0)
            Menu {
                if cloudflare.account == nil {
                    Button("Connect Cloudflare (free)…") { connecting = true }
                } else {
                    Button("Cloudflare account…") { connecting = true }
                }
                if model.isPublished, model.record.host == .cloudflare {
                    Button("Take the page down") { Task { await model.takeDown() } }
                }
                Button("Show the page folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.take.shareBundleFolder])
                }
                .disabled(!FileManager.default.fileExists(atPath: model.take.shareBundleFolder.path))
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("More share page options")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var publishTitle: String {
        let online = cloudflare.account != nil
        if model.isPublished { return online ? "Republish" : "Make folder again" }
        return online ? "Publish link" : "Make page folder"
    }
}

/// The six preset looks as small swatches of the page.
private struct LookPicker: View {
    let selected: SharePageLook.Preset
    let pick: (SharePageLook.Preset) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: Theme.Space.sm)], spacing: Theme.Space.sm) {
            ForEach(SharePageLook.Preset.allCases) { preset in
                let look = SharePageLook(preset)
                Button { pick(preset) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .bottom, spacing: 4) {
                            Circle().strokeBorder(Color(hex: look.ring), lineWidth: 2).frame(width: 10, height: 10)
                            Capsule().fill(Color(hex: look.accent)).frame(height: 5)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottomLeading)
                        .background(Color(hex: look.background), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Color(hex: look.line)))
                        Text(preset.title).textStyle(.caption).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    .padding(5)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(preset == selected ? Theme.text : Theme.line,
                                      lineWidth: preset == selected ? 2 : Theme.Stroke.hairline))
                }
                .buttonStyle(.plain)
                .help(preset.subtitle)
                .accessibilityLabel("\(preset.title) look")
                .accessibilityAddTraits(preset == selected ? .isSelected : [])
            }
        }
    }
}

/// Colours, layout and what viewers can do.
private struct Customise: View {
    @ObservedObject var model: SharePageModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            row("Accent") {
                swatches(SharePageLook.accentChoices, selected: model.record.look.accent) { _ = model.record.look.setAccent($0) }
            }
            row("Background") {
                swatches(SharePageLook.backgroundChoices, selected: model.record.look.background) { model.record.look.background = $0 }
            }
            row("Transcript font") {
                SegmentedTabs(selection: $model.record.look.font, options: SharePageLook.TranscriptFont.allCases) { $0.rawValue.capitalized }
            }
            row("Corners") {
                SegmentedTabs(selection: $model.record.look.corners, options: SharePageLook.Corners.allCases) { $0.rawValue.capitalized }
            }
            row("Transcript") {
                SegmentedTabs(selection: $model.record.look.transcript, options: SharePageLook.TranscriptPlace.allCases) { $0.rawValue.capitalized }
            }
            Toggle("Viewers can ask the video", isOn: $model.record.features.ask).toggleStyle(.ink)
            Toggle("Viewers can react", isOn: $model.record.features.react).toggleStyle(.ink)
            Toggle("Viewers can leave notes", isOn: $model.record.features.notes).toggleStyle(.ink)
            Toggle("Show your button", isOn: $model.record.features.callToAction).toggleStyle(.ink)
            if model.record.features.callToAction {
                HStack(spacing: Theme.Space.sm) {
                    TextField("Button", text: ctaLabel).textFieldStyle(.ink).frame(maxWidth: 120)
                    TextField("https://", text: ctaURL).textFieldStyle(.ink)
                }
            }
            Text("Reactions, notes and insights need Cloudflare connected. Changes show after you republish.")
                .textStyle(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).textStyle(.caption).foregroundStyle(Theme.textMuted)
            content()
        }
    }

    private func swatches(_ colours: [UInt32], selected: UInt32, pick: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(colours, id: \.self) { colour in
                Button { pick(colour) } label: {
                    Circle()
                        .fill(Color(hex: colour))
                        .overlay(Circle().strokeBorder(Theme.line))
                        .frame(width: 20, height: 20)
                        .padding(2)
                        .overlay(Circle().strokeBorder(colour == selected ? Theme.text : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SharePageLook.css(colour))
                .accessibilityAddTraits(colour == selected ? .isSelected : [])
            }
        }
    }

    private var ctaLabel: Binding<String> {
        Binding(get: { model.record.callToAction?.label ?? "" }, set: { label in
            let url = model.record.callToAction?.url ?? URL(string: "https://example.com")!
            model.record.callToAction = label.isEmpty ? nil : .init(label: label, url: url)
        })
    }

    private var ctaURL: Binding<String> {
        Binding(get: { model.record.callToAction?.url.absoluteString ?? "" }, set: { text in
            guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return }
            model.record.callToAction = .init(label: model.record.callToAction?.label ?? "Learn more", url: url)
        })
    }
}

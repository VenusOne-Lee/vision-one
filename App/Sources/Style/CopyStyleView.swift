import AppKit
import SwiftUI
import VisionOneKit

/// Copy a style: drop a video you like (or paste its link), Vision One
/// reads how it's made, and you save that as a template. One column, one
/// obvious button at each step.
struct CopyStyleView: View {
    @ObservedObject var model: CopyStyleModel
    @State private var isTargeted = false
    @State private var canName = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                if let problem = model.problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.error)
                        .padding(Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.errorSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch model.phase {
                case .waiting: dropZone
                case let .reading(progress): reading(progress)
                case .ready: result
                case let .saved(folder): saved(folder)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Copy a style")
                .font(.system(size: 26, weight: .light))
                .accessibilityAddTraits(.isHeader)
            Text("Vision One copies how a video is made, never what's in it. Only the numbers are kept.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: - Waiting

    private var dropZone: some View {
        VStack(spacing: Theme.Space.md) {
            Text("Drop a video you like")
                .font(.system(size: 18, weight: .semibold))
            Text("MP4 or MOV. Vision One reads up to the first \(Int(StyleMeasure.maxSeconds / 60)) minutes.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Button("Choose a video…") { model.choose() }
                .buttonStyle(PillButtonStyle(kind: .primary))
            HStack(spacing: Theme.Space.sm) {
                TextField("…or paste a link", text: $model.pasted)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.openPasted() }
                Button("Read") { model.openPasted() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(model.pastedSource == nil)
            }
            .frame(maxWidth: 460)
            Text(model.pastedSource?.explanation ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, Theme.Space.md)
        .frame(maxWidth: .infinity)
        .background(isTargeted ? Theme.paper : Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [6, 4]))
        )
    }

    // MARK: - Reading

    private func reading(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("Reading \(model.source?.label ?? "the video") on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Stop") { model.stop() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            ProgressView(value: progress)
                .tint(Theme.text)
            if let profile = model.profile {
                VStack(spacing: 0) {
                    liveRow("Cuts found", "\(profile.cuts.times.count)")
                    liveRow("Shot length", profile.cuts.times.count >= 2 ? Self.seconds(profile.cuts.medianShot) : "…")
                    liveRow("Captions", profile.captions?.style.title ?? "None yet")
                    liveRow("Faces", profile.framing.faceShare > 0 ? "\(Int((profile.framing.faceShare * 100).rounded()))% of frames" : "None yet")
                    liveRow("Music", profile.music == nil ? "None yet" : "Yes")
                    liveRow("Shape", "\(profile.format.title) \(profile.format.ratio)")
                }
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line))
            }
            Text("Four frames a second for cuts and colour, one a second for faces and words. Sound is checked for speech and music by macOS.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func liveRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: - Result

    @ViewBuilder
    private var result: some View {
        if let profile = model.profile {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    traits(profile).frame(minWidth: 360)
                    templateCard(profile).frame(width: 280)
                }
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    templateCard(profile)
                    traits(profile)
                }
            }
        }
    }

    private func traits(_ profile: StyleProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Untick anything you don't want copied.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            ForEach(profile.traits) { trait in
                TraitRow(trait: trait, isOn: model.copying.contains(trait.id)) { model.toggle(trait.id) }
            }
        }
    }

    private func templateCard(_ profile: StyleProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("NEW TEMPLATE")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.66)
                .foregroundStyle(Theme.textMuted)
            TextField("Name", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold))
            if canName {
                Button(model.naming ? "Naming…" : "Suggest a name") { Task { await model.suggestName() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .disabled(model.naming)
            }
            Text(CopiedStyle(profile: profile, copying: model.copying).summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !profile.palette.isEmpty {
                HStack(spacing: 6) {
                    ForEach(profile.palette.prefix(5), id: \.hex) { swatch in
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Color(hex: UInt32(swatch.hex.dropFirst(), radix: 16) ?? 0))
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.line))
                            .help(swatch.hex)
                    }
                }
                .opacity(model.copying.contains(.colours) ? 1 : 0.45)
            }
            Button("Save as template") { model.save() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            HStack(spacing: Theme.Space.sm) {
                Button("Start over") { model.reset() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line))
        .task { canName = await model.canSuggestName() }
    }

    // MARK: - Saved

    private func saved(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Saved \u{201C}\(model.title)\u{201D}")
                .font(.system(size: 18, weight: .semibold))
            Text("It's on Home under What are you making?, beside the built-in ones.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: Theme.Space.sm) {
                Button("Copy another") { model.reset() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line))
    }

    static func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
}

/// One trait: solid border when it will be copied, dashed when not
/// (dashed means proposed, solid means accepted).
private struct TraitRow: View {
    let trait: StyleTrait
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trait.id.title.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textMuted)
                    Text(trait.value)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
                    Text(trait.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("\(Int((trait.confidence * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .help("How sure Vision One is")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isOn ? Theme.text : Theme.line,
                                  style: StrokeStyle(lineWidth: 1, dash: isOn ? [] : [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isOn ? "Will be copied" : "Won't be copied")
    }
}

/// The Copy a style window, opened from the File menu and from Home.
@MainActor
final class CopyStyleWindowController: NSObject {
    static let shared = CopyStyleWindowController()
    private var window: NSWindow?
    private let model = CopyStyleModel()

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Copy a Style"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: CopyStyleView(model: model))
            window.setFrameAutosaveName("VisionOneCopyStyleWindow")
            window.center()
            self.window = window
        }
        if case .saved = model.phase { model.reset() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

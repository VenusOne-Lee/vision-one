import AppKit
import AVFoundation
import SwiftUI
import VisionOneKit

/// Export: every place at once. Formats are drawn to their real shape
/// with the camera bubble in the corner; solid ones are picked, dashed
/// ones are suggestions. Caption style sits beside them. "Export N" runs
/// the picked presets one after another, each format filling its own
/// ring. `keep` overrides the kept spans; nil uses the take's edits.json,
/// like the Export menu.
struct ExportSheet: View {
    let take: Take
    let keep: [Range<Double>]?
    let close: () -> Void

    @StateObject private var queue = ExportQueue()
    @ObservedObject private var brand = BrandStore.shared

    @State private var picked: Set<ExportPreset> = [.hd1080]
    @State private var source: ExportSource?
    @State private var duration: Double?
    @State private var loadProblem: String?
    @State private var captions = CaptionSettings()
    @State private var savedCaptions: CaptionSettings?

    init(take: Take, keep: [Range<Double>]?, close: @escaping () -> Void) {
        self.take = take
        self.keep = keep
        self.close = close
    }

    /// The order the design shows caption styles in.
    private static let captionStyles: [CaptionStyle] = [.wordByWord, .keyword, .boldPop, .subtitle]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                formats
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                captionPanel
                    .frame(width: 228)
            }
            .padding(Theme.Space.lg)
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .frame(minWidth: 640, idealWidth: 640, maxWidth: .infinity,
               minHeight: 460, idealHeight: 460, maxHeight: .infinity)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .tint(Theme.text)
        .environment(\.colorScheme, .light)
        .task(id: take.folder) {
            let loaded = take.loadCaptionSettings()
            savedCaptions = loaded
            captions = loaded
            await loadSource()
        }
        .onChange(of: captions) { _, newValue in
            // Saved the way the editor's caption controls save, so the
            // export (which reads captions.json) uses what's shown here.
            guard newValue != savedCaptions else { return }
            try? take.saveCaptionSettings(newValue)
            savedCaptions = newValue
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
            Text(take.shortLabel())
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 14)
    }

    // MARK: - Formats

    private var formats: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Formats")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: Theme.Space.md, alignment: .bottomLeading)],
                      alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(ExportPreset.allCases) { preset in
                    FormatTile(
                        title: preset.title,
                        detail: detail(for: preset),
                        detailIsError: isFailed(preset),
                        aspect: sourceAspect,
                        isPicked: picked.contains(preset),
                        ring: ringColor,
                        progress: queue.batch?.status(of: preset)?.progress,
                        help: help(for: preset),
                        action: { toggle(preset) }
                    )
                    .disabled(queue.isRunning)
                }
                FormatTile(
                    title: "Short",
                    detail: "9:16 · via Clips",
                    detailIsError: false,
                    aspect: 9.0 / 16.0,
                    isPicked: false,
                    ring: ringColor,
                    progress: nil,
                    help: "Vertical exports of the whole video aren't in yet. Make a 9:16 short in the editor's Clips tab.",
                    action: {}
                )
                .disabled(true)
            }
            if let loadProblem {
                Text(loadProblem)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                    .padding(Theme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.errorSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The recording's shape; 16:9 until it has loaded.
    private var sourceAspect: Double {
        guard let source, source.width > 0, source.height > 0 else { return 16.0 / 9.0 }
        return Double(source.width) / Double(source.height)
    }

    private var ringColor: Color { Color(hex: brand.kit.ring.hex) }

    private func estimate(for preset: ExportPreset) -> ExportEstimate? {
        guard let source, let duration else { return nil }
        return ExportEstimate(preset: preset, source: source, duration: duration)
    }

    /// Ratio · length · size, or how the export went once it has run.
    private func detail(for preset: ExportPreset) -> String {
        switch queue.batch?.status(of: preset) {
        case let .done(_, bytes)?:
            return ExportPhase.size(bytes)
        case .failed?:
            return "failed"
        case .cancelled?:
            return "cancelled"
        case .waiting?:
            return "waiting"
        default:
            return estimate(for: preset)?.detail ?? "…"
        }
    }

    private func isFailed(_ preset: ExportPreset) -> Bool {
        if case .failed? = queue.batch?.status(of: preset) { return true }
        return false
    }

    private func help(for preset: ExportPreset) -> String {
        if case let .failed(message)? = queue.batch?.status(of: preset) { return message }
        if let problem = estimate(for: preset)?.problem { return problem }
        return preset.detail
    }

    private func toggle(_ preset: ExportPreset) {
        // Picking again after an export starts a fresh batch.
        queue.reset()
        if picked.contains(preset) {
            picked.remove(preset)
        } else {
            picked.insert(preset)
        }
    }

    // MARK: - Captions

    private var captionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Caption style")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm),
                                GridItem(.flexible(), spacing: Theme.Space.sm)],
                      spacing: Theme.Space.sm) {
                ForEach(Self.captionStyles, id: \.self) { style in
                    CaptionStyleChip(style: style, isPicked: captions.style == style, ring: ringColor) {
                        captions.style = style
                    }
                }
            }
            .disabled(!captions.isOn)
            .opacity(captions.isOn ? 1 : 0.5)
            Text("Keyword colour uses your ring colour.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                switchRow("Captions", isOn: $captions.isOn)
                switchRow("Burn in", isOn: $captions.burnIn)
                    .disabled(!captions.isOn)
                    .help("Draw the captions into the video. Off saves subtitle files only, if they're on in the editor.")
            }
            .padding(.top, Theme.Space.xs)
        }
        // Each preset reads captions.json as it starts, so they stay put
        // until the batch is done.
        .disabled(queue.isRunning)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.text)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.md) {
            footerNote
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") {
                if queue.isRunning {
                    queue.cancel()
                } else {
                    close()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .keyboardShortcut(.cancelAction)
            .help(queue.isRunning ? "Stop exporting" : "Close without exporting")

            if queue.batch?.isFinished == true {
                Button("Done", action: close)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Export \(picked.count)") {
                    queue.export(take, presets: Array(picked), keep: keep)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || queue.isRunning)
                .opacity(picked.isEmpty || queue.isRunning ? 0.5 : 1)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footerNote: some View {
        if let batch = queue.batch, batch.isRunning {
            Text(runningText(batch))
                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        } else if let batch = queue.batch, batch.isFinished {
            HStack(spacing: Theme.Space.sm) {
                Text(finishedText(batch))
                    .font(.system(size: 11))
                    .foregroundStyle(batch.failures.isEmpty ? Theme.textMuted : Theme.error)
                    .lineLimit(2)
                    .help(batch.failures.joined(separator: "\n"))
                if !batch.exported.isEmpty {
                    Button("Show in Finder") { queue.revealExports() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .underline()
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                }
            }
        } else {
            Text("Solid shapes are picked. Dashed ones are suggestions: tap to add.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Exporting 1080p · 1 of 3"
    private func runningText(_ batch: ExportBatch) -> String {
        guard let current = batch.current, let index = batch.presets.firstIndex(of: current) else {
            return "Waiting for the export that's running"
        }
        return "Exporting \(current.title) · \(index + 1) of \(batch.presets.count)"
    }

    private func finishedText(_ batch: ExportBatch) -> String {
        let done = batch.exported.count
        var parts: [String] = []
        if done > 0 { parts.append(done == 1 ? "1 video exported." : "\(done) videos exported.") }
        if let first = batch.failures.first { parts.append(first) }
        if done == 0, batch.failures.isEmpty { parts.append("Export stopped.") }
        return parts.joined(separator: " ")
    }

    // MARK: - Loading

    /// The recording's size and the edited length (cards included), for
    /// the shapes and the line under each one.
    private func loadSource() async {
        let asset = AVURLAsset(url: take.screenURL)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                loadProblem = "This take has no video."
                return
            }
            let size = try await track.load(.naturalSize)
            let rate = try await Double(track.load(.nominalFrameRate))
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite else { return }
            // The same timeline the exporter renders.
            let timeline: ExportTimeline
            if let keep {
                timeline = ExportTimeline(keep: keep, sourceDuration: seconds, frameRate: rate)
            } else {
                var edits = try EditList.load(from: take.editsURL, sourceDuration: seconds)
                edits.sourceDuration = seconds
                timeline = ExportTimeline(edits: edits, frameRate: rate)
            }
            let plan = brand.cardMaker().plan(bodyDuration: timeline.duration)
            source = ExportSource(width: Int(size.width), height: Int(size.height), frameRate: rate)
            duration = plan.duration
            loadProblem = nil
        } catch {
            loadProblem = "Couldn't read this take. \(error.localizedDescription)"
        }
    }
}

// MARK: - Format tile

/// One format drawn at its real shape: an ink outline, solid when picked
/// and dashed when only suggested, with the camera bubble in the builder's
/// ring colour in the corner. While exporting, a dashed ring in the middle
/// fills and closes solid in the ring colour when done.
private struct FormatTile: View {
    let title: String
    let detail: String
    let detailIsError: Bool
    /// Width over height.
    let aspect: Double
    let isPicked: Bool
    let ring: Color
    let progress: Double?
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    /// Every shape fits this box, sitting on its bottom edge.
    static let box = CGSize(width: 96, height: 60)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    Color.clear.frame(width: Self.box.width, height: Self.box.height)
                    shape
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced).monospacedDigit())
                    .foregroundStyle(detailIsError ? Theme.error : Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled || progress != nil || isPicked ? 1 : 0.45)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(isPicked ? "Picked" : "Suggested"), \(detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var shapeSize: CGSize {
        let a = max(aspect, 0.1)
        let width = min(Self.box.width, Self.box.height * a)
        return CGSize(width: width, height: width / a)
    }

    private var shape: some View {
        let size = shapeSize
        let bubble = min(size.width, size.height) * 0.34
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.canvas)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: isPicked ? [] : [4, 3]))
            Circle()
                .fill(Theme.paper)
                .overlay(Circle().strokeBorder(ring, lineWidth: 2))
                .frame(width: bubble, height: bubble)
                .padding(min(size.width, size.height) * 0.1)
            if let progress {
                TileRing(progress: progress, ring: ring)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// ExportRing at tile size: dashed while waiting, an ink arc while
/// exporting, solid in the builder's ring colour once done. Never orange,
/// never green.
private struct TileRing: View {
    let progress: Double

    let ring: Color

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        ZStack {
            Circle().fill(Theme.paper)
            if clamped >= 1 {
                Circle().strokeBorder(ring, lineWidth: 2.5)
            } else {
                Circle()
                    .stroke(Theme.textMuted, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.5]))
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .animation(.easeOut(duration: 0.3), value: clamped)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: - Caption style chip

/// A caption style shown the way the renderer draws it: ink on a white
/// panel, words not said yet muted, keywords in the ring colour.
private struct CaptionStyleChip: View {
    let style: CaptionStyle
    let isPicked: Bool
    let ring: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.sm) {
                sample
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.line, lineWidth: 1))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 6)
            .background(isPicked ? Theme.paper : Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(isPicked ? Theme.text : Theme.line, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var label: String {
        style == .keyword ? "Keyword colour" : style.title
    }

    private var weight: Font.Weight {
        switch style.weight {
        case .medium: return .medium
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    private var sample: Text {
        switch style {
        case .subtitle:
            return Text("I built it in two weekends")
                .font(.system(size: 10.5, weight: weight))
                .foregroundStyle(Theme.text)
        case .wordByWord:
            return (Text("two ").foregroundStyle(Theme.text) + Text("weekends").foregroundStyle(Theme.cutText))
                .font(.system(size: 14, weight: weight))
        case .keyword:
            return (Text("two ").foregroundStyle(Theme.text) + Text("weekends").foregroundStyle(ring))
                .font(.system(size: 14, weight: weight))
        case .boldPop:
            return (Text("two ").foregroundStyle(Theme.text) + Text("weekends").foregroundStyle(ring))
                .font(.system(size: 17, weight: weight))
        }
    }
}

import AppKit
import AVFoundation
import SwiftUI
import VisionOneKit

/// Export: every place at once. Formats are drawn to their real shape
/// with the camera bubble in the corner; solid ones are picked, dashed
/// ones are suggestions. Caption style sits beside them. "Export N" runs
/// the picked presets one after another, each format filling its own
/// ring. The batch runs in the app's one queue, so the sheet can close
/// while it goes. Once done, the sheet becomes the share step: drag or
/// copy a file, or send it to WhatsApp, LinkedIn, X or YouTube with the
/// Sharer's words, approved one post at a time. `keep` overrides the
/// kept spans; nil uses the take's edits.json, like the Export menu.
struct ExportSheet: View {
    let take: Take
    let keep: [Range<Double>]?
    let close: () -> Void

    @ObservedObject private var queue = ExportQueue.shared
    @ObservedObject private var brand = BrandStore.shared

    @State private var picked: Set<ExportPreset>
    /// The take's purpose (plan.json), which picks the first formats.
    private let purpose: Purpose?
    @State private var source: ExportSource?
    @State private var duration: Double?
    @State private var loadProblem: String?
    @State private var captions = CaptionSettings()
    @State private var savedCaptions: CaptionSettings?
    @State private var captionProblem: String?

    init(take: Take, keep: [Range<Double>]?, close: @escaping () -> Void) {
        self.take = take
        self.keep = keep
        self.close = close
        let purpose = TakePlan.load(for: take)?.purpose
        self.purpose = purpose
        _picked = State(initialValue: Set(AppliedTemplate.presets(for: take) ?? purpose.map { ExportPreset.suggested(for: $0) } ?? Self.lastPicked))
    }

    /// What was exported last time, for takes with no purpose.
    private static var lastPicked: [ExportPreset] {
        let saved = (UserDefaults.standard.stringArray(forKey: lastPickedKey) ?? []).compactMap(ExportPreset.init(rawValue:))
        return saved.isEmpty ? [.hd1080] : saved
    }

    private static let lastPickedKey = "export.lastPicked"

    /// This take's batch, if the queue is on it.
    private var batch: ExportBatch? { queue.batch(for: take) }

    private var isExporting: Bool { batch?.isRunning == true }

    /// Another take is exporting; this one waits its turn.
    private var otherIsExporting: Bool { queue.isRunning && batch == nil }

    /// Done with at least one file: the sheet shows the share step.
    private var finishedFiles: Bool { batch?.isFinished == true && !(batch?.exported.isEmpty ?? true) }

    /// The order the design shows caption styles in.
    private static let captionStyles: [CaptionStyle] = [.wordByWord, .keyword, .boldPop, .subtitle]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if let batch, finishedFiles {
                ScrollView {
                    FinishedPanel(take: take, batch: batch, aspect: { $0.format?.aspect ?? sourceAspect })
                        .padding(Theme.Space.lg)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    formats
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    captionPanel
                        .frame(width: 228)
                }
                .padding(Theme.Space.lg)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            if let explanation = CaptionExport.omissionReason(for: take) {
                Text(explanation).textStyle(.caption).foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
            }
            if let captionProblem {
                Text(captionProblem).textStyle(.caption).foregroundStyle(Theme.error).padding(.horizontal, Theme.Space.lg)
            }
            if let warnings = queue.warnings[take.folder], !warnings.isEmpty {
                Text(warnings.joined(separator: "\n")).textStyle(.caption).foregroundStyle(Theme.error)
                    .padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.sm)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .frame(minWidth: 640, idealWidth: 640, maxWidth: .infinity,
               minHeight: 460, idealHeight: 460, maxHeight: .infinity)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .tint(Theme.text)
        .themed()
        .onAppear {
            // Opened again while this take exports: show what's running.
            if let batch { picked = Set(batch.presets) }
        }
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
            do {
                try take.saveCaptionSettings(newValue)
                savedCaptions = newValue
                captionProblem = nil
                NotificationCenter.default.post(name: .takeStyleChanged, object: take.folder)
            } catch { captionProblem = "Couldn't save captions: \(error.localizedDescription)" }
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
            if let purpose {
                Text("Picked for \(purpose.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .help("Formats a \(purpose.title.lowercased()) usually needs. Tap any shape to change.")
            }
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
                        aspect: preset.format?.aspect ?? sourceAspect,
                        isPicked: picked.contains(preset),
                        ring: ringColor,
                        progress: batch?.status(of: preset)?.progress,
                        help: help(for: preset),
                        action: { toggle(preset) }
                    )
                    .disabled(isExporting)
                }
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
        switch batch?.status(of: preset) {
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
        if case .failed? = batch?.status(of: preset) { return true }
        return false
    }

    private func help(for preset: ExportPreset) -> String {
        if case let .failed(message)? = batch?.status(of: preset) { return message }
        if let problem = estimate(for: preset)?.problem { return problem }
        return preset.detail
    }

    private func toggle(_ preset: ExportPreset) {
        // Picking again after an export starts a fresh batch.
        if batch != nil { queue.reset(take) }
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
        .disabled(isExporting)
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
            if isExporting {
                Button("Stop") { queue.cancel(take) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .help("Stop exporting")
                // Closing doesn't stop it: the queue keeps going.
                Button("Close", action: close)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .help("Keeps exporting. Open Export again to see it.")
            } else if batch?.isFinished == true {
                if let batch, batch.presets.contains(where: {
                    switch batch.status(of: $0) {
                    case .failed?, .cancelled?: return true
                    default: return false
                    }
                }) {
                    Button("Retry unfinished") { queue.retry(take) }.buttonStyle(.secondary)
                }
                Button("Export more") { queue.reset(take) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .help("Pick other formats")
                Button("Done", action: close)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .keyboardShortcut(.cancelAction)
                    .help("Close without exporting")
                Button(otherIsExporting ? "Queue \(picked.count)" : "Export \(picked.count)") {
                    let presets = ExportPreset.allCases.filter(picked.contains)
                    UserDefaults.standard.set(presets.map(\.rawValue), forKey: Self.lastPickedKey)
                    queue.export(take, presets: presets, keep: keep)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || captionProblem != nil)
                .opacity(picked.isEmpty || captionProblem != nil ? 0.5 : 1)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footerNote: some View {
        if let position = queue.position(of: take) {
            Text("Queued · position \(position) · uses saved settings when it starts").textStyle(.caption).foregroundStyle(Theme.textMuted)
        } else if let batch, batch.isRunning {
            // Ticks every second so the time left counts down between
            // progress updates.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(runningText(batch, now: context.date))
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        } else if let batch, batch.isFinished {
            Text(finishedText(batch))
                .font(.system(size: 11))
                .foregroundStyle(batch.failures.isEmpty ? Theme.textMuted : Theme.error)
                .lineLimit(2)
                .help(batch.failures.joined(separator: "\n"))
        } else if otherIsExporting {
            Text("Another take is exporting. Add this video to the queue; saved settings are read when it starts.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
        } else {
            Text("Solid shapes are picked. Dashed ones are suggestions: tap to add.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Exporting 1080p · 1 of 3 · about 40 s left"
    private func runningText(_ batch: ExportBatch, now: Date) -> String {
        guard let current = batch.current, let index = batch.presets.firstIndex(of: current) else {
            return "Waiting for the export that's running"
        }
        var text = "Exporting \(current.title) · \(index + 1) of \(batch.presets.count)"
        // Bigger frames take longer, so each format counts by its pixels.
        let progress = ExportProgress.overall(batch) { preset in
            estimate(for: preset).map { Double($0.width * $0.height) } ?? 1
        }
        if let started = queue.startedAt,
           let left = ExportProgress.remaining(progress: progress, elapsed: now.timeIntervalSince(started)) {
            text += " · " + ExportProgress.remainingText(left)
        }
        return text
    }

    private func finishedText(_ batch: ExportBatch) -> String {
        let done = batch.exported.count
        var parts: [String] = []
        if done > 0 { parts.append(done == 1 ? "1 video exported, saved next to the take." : "\(done) videos exported, saved next to the take.") }
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
            let encoded = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displayed = CGRect(origin: .zero, size: encoded).applying(transform)
            let size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
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
            let plan = brand.cardMaker(look: AppliedTemplate.look(for: take), templateFolder: AppliedTemplate.folder(for: take)).plan(bodyDuration: timeline.duration)
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

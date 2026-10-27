import AppKit
import SwiftUI
import VisionOneKit

/// One take in the Library: its frame (hover to scrub through it), the
/// length on the frame, its name, what it's for and where it's up to.
/// The ring is dashed until the take is exported, then solid, the app's
/// one grammar. Rename in place; Move to Trash can be undone.
struct TakeCard: View {
    let item: LibraryItem
    /// Bumped on every Library refresh so the frame is read again.
    let generation: Int
    /// The newest take while recording is still being saved.
    let isBusy: Bool
    let open: () -> Void
    let rename: (String) -> Void
    let trash: () -> Void

    @State private var firstFrame: CGImage?
    @State private var scrubFrame: CGImage?
    @State private var loaded = false
    /// 0...1 across the frame while the pointer is over it.
    @State private var scrub: CGFloat?
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var scrubStep: Int? {
        scrubFraction.map { min(LibraryPreviews.scrubSteps - 1, Int($0 * CGFloat(LibraryPreviews.scrubSteps))) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) { thumbnail }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(item.title)")
            details
        }
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(isHovering ? Theme.text : Theme.line, lineWidth: isHovering ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu { actions }
        .task(id: generation) {
            firstFrame = await LibraryPreviews.shared.firstFrame(for: item.take)
            loaded = true
        }
        .task(id: scrubStep) {
            guard let step = scrubStep, let duration = item.duration else {
                scrubFrame = nil
                return
            }
            scrubFrame = await LibraryPreviews.shared.scrubFrame(for: item.take, step: step, duration: duration)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Open") { open() }
        Button("Rename…") { startRenaming() }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.take.screenURL])
        }
        Divider()
        Button("Move to Trash", role: .destructive) { trash() }
            .disabled(isBusy)
    }

    // MARK: Frame

    private var thumbnail: some View {
        // The canvas sets the 16:10 box; the frame fills it without
        // pushing the card wider.
        Rectangle()
            .fill(Theme.canvas)
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = scrubFrame ?? firstFrame {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .overlay(alignment: .bottomTrailing) { lengthBadge }
            .overlay(alignment: .bottom) { scrubLine }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.lg, topTrailingRadius: Theme.Radius.lg))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(point): scrub = point.x
                case .ended: scrub = nil
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
    }

    /// Set from the frame's width so the hover point becomes 0...1.
    @State private var width: CGFloat = 1

    private var scrubFraction: CGFloat? {
        scrub.map { min(1, max(0, $0 / max(width, 1))) }
    }

    /// "2:13" in white on ink, bottom right of the frame.
    @ViewBuilder
    private var lengthBadge: some View {
        if let duration = item.duration {
            Text(Timecode.short(from: scrubFraction.map { duration * Double($0) } ?? duration))
                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.paper)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.text.opacity(0.82), in: Capsule())
                .padding(Theme.Space.sm)
                .accessibilityLabel("\(Int(duration.rounded())) seconds long")
        }
    }

    /// A thin ink line showing where the hover is in the take.
    @ViewBuilder
    private var scrubLine: some View {
        if let fraction = scrubFraction {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Theme.text)
                    .frame(width: proxy.size.width * fraction, height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Name and status

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ring
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(finishRenaming)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused && isRenaming { finishRenaming() }
                        }
                } else {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .onTapGesture(count: 2, perform: startRenaming)
                        .help("Double-click to rename")
                }
                Spacer(minLength: 0)
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("More for \(item.title)")
            }
            Text(metaLine)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(Theme.Space.sm + 2)
    }

    /// "Demo · 3 suggested cuts", or the date when the take has a typed
    /// name, so nothing the builder needs is hidden.
    private var metaLine: String {
        var parts: [String] = []
        let dated = item.take.shortLabel()
        if item.title != dated { parts.append(dated) }
        if let purpose = item.purposeTitle { parts.append(purpose) }
        if item.suggestedCuts > 0 {
            parts.append("\(item.suggestedCuts) suggested \(item.suggestedCuts == 1 ? "cut" : "cuts")")
        } else if item.transcriptText == nil && !item.isExported
                    && !FileManager.default.fileExists(atPath: item.take.transcriptFailedURL.path) {
            parts.append("Transcript on its way")
        }
        parts.append(item.isExported ? "Exported" : "Not exported")
        return parts.joined(separator: " · ")
    }

    private var ring: some View {
        Circle()
            .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: item.isExported ? [] : [3, 3]))
            .frame(width: 14, height: 14)
            .accessibilityLabel(item.isExported ? "Exported" : "Not exported")
    }

    private func startRenaming() {
        draft = item.take.customTitle() ?? ""
        isRenaming = true
        // The field only exists from the next pass.
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        rename(draft)
    }
}

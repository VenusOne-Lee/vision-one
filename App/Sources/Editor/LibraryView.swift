import AppKit
import AVFoundation
import SwiftUI
import VisionOneKit

/// The main window's home when no take is open (design v2, "Home: say
/// what it's for, then record"): pick what you're making on the left, the
/// record pane on the right, and every take below as a card, newest first.
/// Two columns stack into one under 900 pt. Clicking a card opens it in
/// the editor in the same window.
struct LibraryView: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    let open: (Take) -> Void
    /// Read again whenever the window comes forward or a take finishes,
    /// the same way the editor's takes sidebar does.
    @State private var takes: [Take] = TakeLibrary.standard.takes()
    /// Bumped on every refresh so cards read their status from disk again
    /// (a transcript or an export may have landed meanwhile).
    @State private var generation = 0
    @State private var width: CGFloat = 1000
    /// What the next take is for; empty means "Just record, decide later".
    @AppStorage("home.purposeID") private var purposeID = ""

    /// Below this the record pane moves under the cards.
    private static let stackWidth: CGFloat = 900
    private static let paneWidth: CGFloat = 300

    private var isWide: Bool { width >= Self.stackWidth }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                launcher
                Divider().overlay(Theme.line)
                recentTakes
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
        .background(HomeWindowSubtitle(text: weekLine))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
        .onReceive(recorder.$lastTake) { _ in refresh() }
        .onChange(of: purposeID) { _, newID in carryPurposeToNextTake(newID) }
    }

    private func refresh() {
        let latest = TakeLibrary.standard.takes()
        if latest != takes { takes = latest }
        generation += 1
    }

    /// The Producer and the Agents read "ai.nextPurpose" when the next
    /// take's plan.json is made, so Home's pick lands there too. Just
    /// record clears it, and they fall back to their default.
    private func carryPurposeToNextTake(_ id: String) {
        if id.isEmpty || Purpose.named(id) == nil {
            UserDefaults.standard.removeObject(forKey: "ai.nextPurpose")
        } else {
            UserDefaults.standard.set(id, forKey: "ai.nextPurpose")
        }
    }

    /// "3 takes this week", for the window's title bar.
    private var weekLine: String {
        let calendar = Calendar.current
        let now = Date()
        let count = takes.filter { take in
            take.recordedAt(timeZone: calendar.timeZone)
                .map { calendar.isDate($0, equalTo: now, toGranularity: .weekOfYear) } ?? false
        }.count
        switch count {
        case 0: return "No takes this week"
        case 1: return "1 take this week"
        default: return "\(count) takes this week"
        }
    }

    // MARK: Launcher

    @ViewBuilder
    private var launcher: some View {
        if isWide {
            HStack(alignment: .top, spacing: 0) {
                purposePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.paper)
                HomeRecordPane()
                    .padding(Theme.Space.lg)
                    .frame(width: Self.paneWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.canvas)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.line).frame(width: 1)
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                purposePane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Theme.paper)
                HomeRecordPane()
                    .frame(maxWidth: 360)
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity)
                    .background(Theme.canvas)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
            }
        }
    }

    private var purposePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What are you making?")
                .font(.system(size: 30, weight: .light))
                .tracking(-0.9)
                .accessibilityAddTraits(.isHeader)
            HomePurposeGrid(selectedID: $purposeID, columns: purposeColumns)
        }
        .padding(28)
    }

    /// Three columns, two when the cards' side is narrow (design: 640).
    private var purposeColumns: Int {
        let side = isWide ? width - Self.paneWidth : width
        return side < 640 ? 2 : 3
    }

    // MARK: Recent takes

    private var recentTakes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Text("Recent takes")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if !takes.isEmpty {
                    Text("\(takes.count)")
                        .font(.system(size: 12, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            if takes.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.md)],
                          spacing: Theme.Space.md) {
                    ForEach(takes, id: \.folder) { take in
                        TakeCard(take: take, generation: generation) { open(take) }
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        HStack(spacing: Theme.Space.sm) {
            Circle()
                .strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text("No recordings yet. Press ⌘⇧R or the record button to make your first take.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity)
    }
}

/// What a take's files on disk say about it, for the card's status line.
struct TakeStatus: Equatable, Sendable {
    enum Transcript: Equatable, Sendable { case waiting, ready, unavailable }

    var transcript: Transcript
    /// Cuts auto-clean proposed that are still waiting for a decision.
    var suggestedCuts: Int
    /// Any export preset's file exists next to the recording.
    var isExported: Bool

    init(take: Take, fileManager: FileManager = .default) {
        if fileManager.fileExists(atPath: take.transcriptURL.path) {
            transcript = .ready
        } else if fileManager.fileExists(atPath: take.transcriptFailedURL.path) {
            transcript = .unavailable
        } else {
            transcript = .waiting
        }
        let edits = try? EditList.read(from: take.editsURL)
        suggestedCuts = edits?.cuts.filter { $0.state == .proposed }.count ?? 0
        isExported = ExportPreset.allCases.contains {
            fileManager.fileExists(atPath: take.exportURL(for: $0).path)
        }
    }

    var line: String {
        var parts: [String] = []
        switch transcript {
        case .waiting: parts.append("Transcript on its way")
        case .ready: parts.append("Transcript ready")
        case .unavailable: parts.append("No transcript")
        }
        if suggestedCuts > 0 {
            parts.append("\(suggestedCuts) suggested \(suggestedCuts == 1 ? "cut" : "cuts")")
        }
        parts.append(isExported ? "Exported" : "Not exported")
        return parts.joined(separator: " · ")
    }
}

/// One take: its first frame, when it was recorded, how long it runs and
/// where it's up to. The ring is dashed until the take is exported, then
/// solid, the app's one grammar.
private struct TakeCard: View {
    let take: Take
    let generation: Int
    let open: () -> Void
    @State private var preview: LibraryPreviews.Preview?
    @State private var status: TakeStatus?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ring
                        Text(take.shortLabel())
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let duration = preview?.duration {
                            Text(Timecode.short(from: duration))
                                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    Text(status?.line ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(Theme.Space.sm + 2)
            }
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .help(take.name)
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([take.screenURL])
            }
        }
        .task(id: generation) {
            // Cached after the first frame loads, so a refresh is cheap.
            preview = await LibraryPreviews.shared.preview(for: take)
            let current = self.take
            status = await Task.detached(priority: .utility) { TakeStatus(take: current) }.value
        }
    }

    private var thumbnail: some View {
        // The canvas sets the 16:10 box; the frame fills it without
        // pushing the card wider.
        Rectangle()
            .fill(Theme.canvas)
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = preview?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if preview == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.lg, topTrailingRadius: Theme.Radius.lg))
            .accessibilityHidden(true)
    }

    private var ring: some View {
        Circle()
            .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5,
                                                         dash: status?.isExported == true ? [] : [3, 3]))
            .frame(width: 14, height: 14)
            .accessibilityLabel(status?.isExported == true ? "Exported" : "Not exported")
    }
}

/// First frames and durations of takes, made once per launch and kept in
/// memory so scrolling and coming back to the Library stay instant.
@MainActor
final class LibraryPreviews {
    static let shared = LibraryPreviews()

    struct Preview {
        var image: CGImage?
        var duration: Double?
    }

    private var cache: [URL: Preview] = [:]

    func preview(for take: Take) async -> Preview {
        if let cached = cache[take.folder] { return cached }
        let asset = AVURLAsset(url: take.screenURL)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 300)
        let image = try? await generator.image(at: .zero).image
        let preview = Preview(image: image, duration: seconds.isFinite && seconds > 0 ? seconds : nil)
        // A take still being written has no frame yet: try again next time.
        if image != nil { cache[take.folder] = preview }
        return preview
    }
}

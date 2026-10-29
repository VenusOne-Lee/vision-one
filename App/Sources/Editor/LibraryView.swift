import AppKit
import SwiftUI
import VisionOneKit

/// Every take, newest first, as a plain list: its frame, name, when it
/// was recorded, how long it is and the first words said in it. Search
/// finds names and anything said; double-click a name to rename it, and
/// Move to Trash can be undone. Starting new work lives on New task, so
/// the Library is only for finding takes. Clicking a row opens its task.
struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var recorder = ScreenRecorder.shared
    let open: (Take) -> Void
    private let library: TakeLibrary
    /// Read again whenever the window comes forward or a take finishes,
    /// the same way the harness reads its takes.
    @State private var takes: [Take]
    @State private var items: [TakeListing] = []
    @State private var indexed = false
    /// Bumped on every refresh so rows read their frame from disk again
    /// (a transcript or an export may have landed meanwhile).
    @State private var generation = 0
    @State private var search = ""
    @State private var filter: LibraryFilter = .all
    @FocusState private var searchFocused: Bool
    /// The last take moved to the Trash, for Undo.
    @State private var trashed: Trashed?
    @State private var fileProblem: String?
    @AppStorage("library.sort") private var sort = LibrarySort.newest

    init(library: TakeLibrary = .standard, initialQuery: LibraryQuery = LibraryQuery(), open: @escaping (Take) -> Void) {
        self.library = library
        self.open = open
        _takes = State(initialValue: library.takes())
        _search = State(initialValue: initialQuery.search)
        _filter = State(initialValue: initialQuery.filter)
    }

    private var query: LibraryQuery { LibraryQuery(search: search, filter: filter, sort: sort) }

    var body: some View {
        ScrollView {
            takesSection
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) { trashToast }
        .alert("Library action failed", isPresented: Binding(get: { fileProblem != nil }, set: { if !$0 { fileProblem = nil } })) {
            Button("OK") { fileProblem = nil }
        } message: { Text(fileProblem ?? "") }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .themed()
        .background {
            // ⌘F jumps to search from anywhere in the Library.
            Button("Search takes") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
        .onReceive(recorder.$lastTake) { _ in refresh() }
        .task(id: generation) {
            items = await LibraryIndex.shared.items(for: takes)
            indexed = true
        }
    }

    private func refresh() {
        let latest = library.takes()
        if latest != takes { takes = latest }
        generation += 1
    }

    // MARK: Takes

    private var shown: [TakeListing] { query.apply(to: items) }

    private var takesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("Library").textStyle(.title)
                Spacer()
                Button("Import a video…") { HarnessModel.shared.importVideo() }
                    .buttonStyle(.secondary)
            }
            if let next = pickUp {
                PickUpBanner(item: next) { open(next.take) }
            }
            if takes.isEmpty {
                EmptyState("No takes yet",
                           message: "Every take you record lands here, with its words to search. ⇧⌘R records from anywhere.",
                           action: (title: recorder.phase.isLive ? "Stop recording" : "Record your first take",
                                    run: {
                                        if recorder.phase.isLive { Task { await ScreenRecorder.shared.toggle() } }
                                        else { HarnessModel.shared.preparingRecording = true }
                                    }))
                    .disabled(recorder.phase.isBusy)
            } else {
                takesHeader
                if !indexed {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(Theme.Space.lg)
                } else if shown.isEmpty {
                    noMatches
                } else {
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(shown, id: \.take.folder) { item in
                            LibraryRow(item: item, generation: generation,
                                       isBusy: recorder.phase.isLive && item.take == takes.first,
                                       open: { open(item.take) },
                                       rename: { title in try rename(item.take, to: title) },
                                       trash: { moveToTrash(item) },
                                       onRenameFailure: { error in
                                           fileProblem = "Couldn't rename this video: \(error.localizedDescription). Your draft is kept; choose Retry rename."
                                       })
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The newest take, when it still has cuts waiting for a yes or no:
    /// one click back to where the builder left off.
    private var pickUp: TakeListing? {
        guard let newest = items.first(where: { $0.take == takes.first }),
              newest.needsReview, !newest.isExported, !recorder.phase.isLive else { return nil }
        return newest
    }

    private var takesHeader: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Takes")
                .textStyle(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("\(takes.count)")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            searchField
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }
            } label: { Label(filter.label, systemImage: "line.3.horizontal.decrease") }
            sortMenu
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("Search names and what you said", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280)
        .background(Theme.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(searchFocused ? Theme.text : Theme.line, lineWidth: 1))
        .help("Search takes (⌘F)")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(sort.label)
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Sort takes")
    }

    private var noMatches: some View {
        VStack(spacing: Theme.Space.sm) {
            Text(query.emptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
            Button("Show every take") {
                var reset = query
                reset.showEveryTake()
                search = reset.search
                filter = reset.filter
            }
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
    }

    // MARK: Rename and Trash

    private func rename(_ take: Take, to title: String) throws {
        try take.setTitle(title)
        generation += 1
    }

    private struct Trashed: Equatable {
        let title: String
        let original: URL
        let inTrash: URL
    }

    /// Like Finder: no question first, and Undo puts it back.
    private func moveToTrash(_ item: TakeListing) {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: item.take.folder, resultingItemURL: &resulting)
        } catch {
            fileProblem = "Couldn't move this video to the Trash: \(error.localizedDescription)"
            return
        }
        if let inTrash = resulting as URL? {
            WorkspaceMotion.perform(reduced: reduceMotion) { trashed = Trashed(title: item.title, original: item.take.folder, inTrash: inTrash) }
        }
        refresh()
    }

    private func undoTrash() {
        guard let trashed else { return }
        do {
            try FileManager.default.moveItem(at: trashed.inTrash, to: trashed.original)
            WorkspaceMotion.perform(reduced: reduceMotion) { self.trashed = nil }
            refresh()
        } catch {
            fileProblem = "Couldn't restore this video. It remains in the Trash: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var trashToast: some View {
        if let trashed {
            HStack(spacing: Theme.Space.md) {
                Text("Moved “\(trashed.title)” to the Trash")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Undo", action: undoTrash)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.leading, Theme.Space.md)
            .padding(.trailing, Theme.Space.sm)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .padding(.bottom, Theme.Space.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: trashed) {
                // A newer trash restarts the wait; only a full wait hides it.
                guard (try? await Task.sleep(for: .seconds(8))) != nil else { return }
                guard fileProblem == nil else { return }
                WorkspaceMotion.perform(reduced: reduceMotion) { self.trashed = nil }
            }
        }
    }
}

/// One take in the Library: its first frame, name, date and length, and
/// the first words said. The ring is dashed until the take is exported,
/// then solid. Double-click the name to rename; Move to Trash is in the
/// ⋯ and right-click menus.
private struct LibraryRow: View {
    let item: TakeListing
    /// Bumped on every Library refresh so the frame is read again.
    let generation: Int
    /// The newest take while recording is still being saved.
    let isBusy: Bool
    let open: () -> Void
    let rename: (String) throws -> Void
    let trash: () -> Void
    let onRenameFailure: (Error) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var frame: CGImage?
    @State private var loaded = false
    @State private var isHovering = false
    @State private var renameDraft = LibraryRenameDraft()
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            Button(action: open) { thumbnail }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(item.title)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ring
                    name
                    if renameDraft.needsRetry {
                        Button("Retry rename", action: startRenaming).buttonStyle(.plain)
                    }
                }
                // The name keeps double-click for renaming; the lines
                // under it open the take like the frame does.
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metaLine)
                            .font(.system(size: 11, design: .monospaced).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                        Text(previewLine)
                            .textStyle(.caption)
                            .foregroundStyle(item.transcriptPreview() == nil ? Theme.textFaint : Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the take")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel("More for \(item.title)")
        }
        .padding(Theme.Space.sm)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(isHovering ? Theme.text : Theme.line, lineWidth: Theme.Stroke.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .contextMenu { actions }
        .task(id: generation) {
            frame = await LibraryPreviews.shared.firstFrame(for: item.take)
            loaded = true
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

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(Theme.canvas)
            .frame(width: 112, height: 70)
            .overlay {
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var name: some View {
        if renameDraft.isEditing {
            TextField("Name", text: $renameDraft.text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused($nameFocused)
                .onSubmit(finishRenaming)
                .onExitCommand { renameDraft.cancel() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused && renameDraft.isEditing { finishRenaming() }
                }
        } else {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2, perform: startRenaming)
                .help("Double-click to rename")
        }
    }

    /// "Today at 14:41 · 2:13 · 3 suggested cuts". The date shows even
    /// when the title is the date, so every row reads the same way.
    private var metaLine: String {
        var parts = [item.take.shortLabel()]
        if let duration = item.duration { parts.append(Timecode.short(from: duration)) }
        if item.suggestedCuts > 0 {
            parts.append("\(item.suggestedCuts) suggested \(item.suggestedCuts == 1 ? "cut" : "cuts")")
        }
        return parts.joined(separator: " · ")
    }

    /// The first words said, or why there aren't any.
    private var previewLine: String {
        if let preview = item.transcriptPreview() { return preview }
        if FileManager.default.fileExists(atPath: item.take.transcriptFailedURL.path) {
            return "No words in this take"
        }
        return item.transcriptText == nil ? "Transcript on its way" : "Nothing was said"
    }

    private var ring: some View {
        Circle()
            .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.ring,
                                                         dash: item.isExported ? [] : Theme.Stroke.dash))
            .frame(width: 14, height: 14)
            .accessibilityLabel(item.isExported ? "Exported" : "Not exported")
            .help(item.isExported ? "Exported" : "Not exported yet")
    }

    private func startRenaming() {
        renameDraft.begin(title: item.take.customTitle() ?? "")
        // The field only exists from the next pass.
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRenaming() {
        guard renameDraft.isEditing else { return }
        do { try renameDraft.finish(save: rename) }
        catch { onRenameFailure(error) }
    }
}

/// "Your last take has 3 suggested cuts", with one button back into it.
private struct PickUpBanner: View {
    let item: TakeListing
    let review: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Circle()
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(item.title) has \(item.suggestedCuts) suggested \(item.suggestedCuts == 1 ? "cut" : "cuts") ready to review.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Space.sm)
            Button("Review", action: review)
                .buttonStyle(PillButtonStyle(kind: .primary))
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

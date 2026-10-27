import AppKit
import SwiftUI
import VisionOneKit

/// The main window's home when no take is open (design v2, "Home: say
/// what it's for, then record"): pick what you're making on the left, the
/// record pane on the right, and every take below as a card, newest first.
/// Two columns stack into one under 900 pt. The takes can be searched (by
/// name or anything said in them), filtered, sorted and resized. Clicking
/// a card opens it in the editor in the same window.
struct LibraryView: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    let open: (Take) -> Void
    /// Read again whenever the window comes forward or a take finishes,
    /// the same way the editor's takes sidebar does.
    @State private var takes: [Take] = TakeLibrary.standard.takes()
    @State private var items: [TakeListing] = []
    @State private var indexed = false
    /// Bumped on every refresh so cards read their frame from disk again
    /// (a transcript or an export may have landed meanwhile).
    @State private var generation = 0
    @State private var width: CGFloat = 1000
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    /// The last take moved to the Trash, for Undo.
    @State private var trashed: Trashed?
    /// What the next take is for; empty means "Just record, decide later".
    @AppStorage("home.purposeID") private var purposeID = ""
    @AppStorage("home.showPurposes") private var showPurposes = true
    @AppStorage("library.filter") private var filter = LibraryFilter.all
    @AppStorage("library.sort") private var sort = LibrarySort.newest
    /// The smallest a card gets; the slider under the search sets it.
    @AppStorage("library.cardWidth") private var cardWidth = 240.0

    /// Below this the record pane moves under the cards.
    private static let stackWidth: CGFloat = 900
    private static let paneWidth: CGFloat = 300

    private var isWide: Bool { width >= Self.stackWidth }
    private var query: LibraryQuery { LibraryQuery(search: search, filter: filter, sort: sort) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                launcher
                Divider().overlay(Theme.line)
                takesSection
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .overlay(alignment: .bottom) { trashToast }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
        .background(HomeWindowSubtitle(text: weekLine))
        .background {
            // ⌘F jumps to search from anywhere on Home.
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
        .onChange(of: purposeID) { _, newID in carryPurposeToNextTake(newID) }
        .task(id: generation) {
            items = await LibraryIndex.shared.items(for: takes)
            indexed = true
        }
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

    /// The cards fold away to one line ("Making: Demo") for people who
    /// just record; the choice is remembered either way.
    private var purposePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text("What are you making?")
                    .font(.system(size: showPurposes ? 30 : 20, weight: .light))
                    .tracking(showPurposes ? -0.9 : -0.4)
                    .accessibilityAddTraits(.isHeader)
                if !showPurposes {
                    Text(Purpose.named(purposeID)?.title ?? "Just record")
                        .font(.system(size: 20, weight: .semibold))
                }
                Spacer(minLength: Theme.Space.sm)
                Button(showPurposes ? "Hide" : "Change") {
                    withAnimation(.easeInOut(duration: 0.2)) { showPurposes.toggle() }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help(showPurposes ? "Fold the cards away; your pick stays" : "Show what you can make")
            }
            if showPurposes {
                HomePurposeGrid(selectedID: $purposeID, columns: purposeColumns)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(showPurposes ? 28 : 20)
    }

    /// Three columns, two when the cards' side is narrow (design: 640).
    private var purposeColumns: Int {
        let side = isWide ? width - Self.paneWidth : width
        return side < 640 ? 2 : 3
    }

    // MARK: Takes

    private var shown: [TakeListing] { query.apply(to: items) }

    private var takesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let next = pickUp {
                PickUpBanner(item: next) { open(next.take) }
            }
            if !takes.isEmpty {
                takesHeader
                filterChips
            }
            if takes.isEmpty {
                LibraryEmptyState { Task { await recorder.toggle() } }
            } else if !indexed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(Theme.Space.lg)
            } else if shown.isEmpty {
                noMatches
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth), spacing: Theme.Space.md)],
                          spacing: Theme.Space.md) {
                    ForEach(shown, id: \.take.folder) { item in
                        TakeCard(item: item, generation: generation,
                                 isBusy: recorder.phase.isLive && item.take == takes.first) {
                            open(item.take)
                        } rename: { title in
                            rename(item.take, to: title)
                        } trash: {
                            moveToTrash(item)
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
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("\(takes.count)")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            searchField
            sortMenu
            sizeSlider
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

    /// Small cards to big ones; remembered.
    private var sizeSlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.3x3").font(.system(size: 10))
            Slider(value: $cardWidth, in: 180...420)
                .controlSize(.mini)
                .frame(width: 80)
                .accessibilityLabel("Card size")
            Image(systemName: "square.grid.2x2").font(.system(size: 12))
        }
        .foregroundStyle(Theme.textMuted)
        .help("Card size")
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(LibraryFilter.allCases, id: \.self) { option in
                let count = items.filter(option.includes).count
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 4) {
                        Text(option.label)
                        if option != .all {
                            Text("\(count)").monospacedDigit().opacity(0.7)
                        }
                    }
                }
                .buttonStyle(ChipStyle(isOn: filter == option))
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
    }

    private var noMatches: some View {
        VStack(spacing: Theme.Space.sm) {
            Text(search.isEmpty ? "No takes here yet." : "Nothing matches “\(search)”.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
            Button("Show every take") {
                search = ""
                filter = .all
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.lg)
    }

    // MARK: Rename and Trash

    private func rename(_ take: Take, to title: String) {
        try? take.setTitle(title)
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
            NSSound.beep()
            return
        }
        if let inTrash = resulting as URL? {
            withAnimation { trashed = Trashed(title: item.title, original: item.take.folder, inTrash: inTrash) }
        }
        refresh()
    }

    private func undoTrash() {
        guard let trashed else { return }
        try? FileManager.default.moveItem(at: trashed.inTrash, to: trashed.original)
        withAnimation { self.trashed = nil }
        refresh()
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
                withAnimation { self.trashed = nil }
            }
        }
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

/// No takes yet: how it works in three steps, and one way to start.
private struct LibraryEmptyState: View {
    let record: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("Your first take starts here")
                .font(.system(size: 26, weight: .light))
                .tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                step(1, "Record", "Press record or ⌘⇧R and talk it through.")
                step(2, "Review", "Vision One trims the ums and long pauses for you.")
                step(3, "Export", "Every size at once, with captions.")
            }
            Button("Start recording", action: record)
                .buttonStyle(PillButtonStyle(kind: .primary))
        }
        .padding(Theme.Space.lg + Theme.Space.sm)
        .frame(maxWidth: .infinity)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        VStack(spacing: Theme.Space.sm) {
            ZStack {
                Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Text("\(number)").font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .frame(width: 30, height: 30)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 170)
        .accessibilityElement(children: .combine)
    }
}

/// A filter pill: ink when on, white with a line when off.
private struct ChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? Theme.paper : Theme.text)
            .background(Capsule().fill(isOn ? Theme.text : Theme.paper))
            .overlay(Capsule().strokeBorder(isOn ? Theme.text : Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

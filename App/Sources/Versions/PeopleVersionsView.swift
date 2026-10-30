import SwiftUI
import UniformTypeIdentifiers
import VisionOneKit

/// Paste a list on the left, see each person's title card on the right,
/// make them all with one button. The divider drags; the preview grid
/// fits as many cards per row as the width allows.
struct PeopleVersionsView: View {
    @ObservedObject var model: PeopleVersionsModel
    @AppStorage("versions.listWidth") private var listWidth: Double = 320
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                listPane
                    .frame(width: CGFloat(listWidth))
                divider
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().overlay(Theme.line)
            footer
        }
        .background(Theme.canvas)
        .frame(minWidth: 620, minHeight: 460)
        .themed()
    }

    // MARK: List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Who it's for").textStyle(.headline).foregroundStyle(Theme.text)
            Text("Paste names, one a line, or a sheet with name, company and email columns.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.pasted)
                    .font(.ds(.monoSmall))
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.xs)
                    .disabled(model.isMaking)
                if model.pasted.isEmpty {
                    Text("name, company, email\nThandi Mokoena, Joburg Taxi Association, thandi@…\nPieter van Wyk <pieter@…>")
                        .font(.ds(.monoSmall))
                        .foregroundStyle(Theme.textFaint)
                        .padding(Theme.Space.sm)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(dropping ? Theme.text : Theme.lineStrong,
                              style: StrokeStyle(lineWidth: dropping ? Theme.Stroke.ring : Theme.Stroke.hairline,
                                                 dash: dropping ? Theme.Stroke.dash : [])))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.load(url) }
                }
                return true
            }
            HStack {
                Button("Choose a file…") { model.chooseFile() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    .disabled(model.isMaking)
                Spacer()
                Text(listSummary).textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
            if !model.list.problems.isEmpty {
                Notice(.info, lead: "\(model.list.problems.count) \(model.list.problems.count == 1 ? "row has" : "rows have") no name",
                       detail: model.list.problems.prefix(3).map { "Line \($0.line): \($0.text)" }.joined(separator: "\n"))
            }
            cardSettings
        }
        .padding(Theme.Space.md)
        .background(Theme.paper)
    }

    private var listSummary: String {
        let list = model.list
        guard list.count > 0 else { return "No one yet" }
        var parts = ["\(list.count) \(list.count == 1 ? "person" : "people")"]
        if list.repeats > 0 { parts.append("\(list.repeats) repeat\(list.repeats == 1 ? "" : "s") skipped") }
        if list.overLimit > 0 { parts.append("\(list.overLimit) over the \(RecipientList.maxRecipients) limit") }
        return parts.joined(separator: " · ")
    }

    private var cardSettings: some View {
        CollapsibleSection("Title card", id: "versions.card", summary: model.settings.titleCard ? model.settings.headline.template : "Off") {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Toggle("Show a card with their name first", isOn: $model.settings.titleCard)
                    .toggleStyle(.ink)
                if model.settings.titleCard {
                    TextField("Made for {first name|you}", text: $model.settings.headline.template)
                        .textFieldStyle(.ink)
                        .accessibilityLabel("First line")
                    TextField("{company}", text: $model.settings.subline.template)
                        .textFieldStyle(.ink)
                        .accessibilityLabel("Second line")
                    Text("Use {first name}, {name}, {company} or any column. Add a fallback after a bar: {company|your team}.")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("On screen").textStyle(.caption).foregroundStyle(Theme.textMuted)
                        Slider(value: $model.settings.cardDuration, in: VersionSettings.durationRange, step: 0.5)
                        Mono(String(format: "%.1f s", model.settings.clampedDuration), small: true)
                    }
                }
                if !model.captionLanguages.isEmpty {
                    Toggle("Captions in each person's language, when the list has a language column",
                           isOn: $model.settings.captionsInTheirLanguage)
                        .toggleStyle(.ink)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                listWidth = min(max(listWidth + Double(value.translation.width), 260), 520)
            })
            .onTapGesture(count: 2) { listWidth = 320 }
            .accessibilityHidden(true)
    }

    // MARK: Preview

    private var previewPane: some View {
        Group {
            if model.versions.isEmpty {
                EmptyState("One demo, many people",
                           message: "Paste a list on the left. Each person gets their own copy with their name on the title card, made on this Mac.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: Theme.Space.md)],
                              spacing: Theme.Space.md) {
                        ForEach(model.versions) { version in
                            VersionCard(version: version, titleCard: model.settings.titleCard,
                                        ring: BrandStore.shared.kit.ring, state: model.rows[version.id] ?? .ready)
                        }
                    }
                    .padding(Theme.Space.md)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            switch model.phase {
            case .editing:
                Text(model.versions.isEmpty ? "Files go in the take's Versions folder, with versions.csv for your mail merge."
                     : "\(model.estimate). Files go in the take's Versions folder.")
                    .textStyle(.caption).foregroundStyle(Theme.textMuted)
            case let .making(done, total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Theme.text)
                    .frame(width: 140)
                Text("Making \(min(done + 1, total)) of \(total) · Esc to stop")
                    .textStyle(.caption).foregroundStyle(Theme.textMuted)
            case let .finished(made, failed):
                Text(AgentReceipt.versions(made: made, failed: failed))
                    .textStyle(.caption).foregroundStyle(Theme.text)
            }
            Spacer()
            Picker("Format", selection: $model.preset) {
                ForEach([ExportPreset.hd1080, .hd720, .whatsapp, .vertical, .square, .portrait]) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.isMaking)
            if model.isMaking {
                Button("Stop") { model.cancel() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            } else if case .finished = model.phase {
                Button("Show in Finder") { model.reveal() }
                    .buttonStyle(.primary)
            } else {
                Button(model.versions.count == 1 ? "Make 1 version" : "Make \(model.versions.count) versions") { model.make() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.versions.isEmpty)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.paper)
    }
}

/// One person's copy: their title card as it will look, their name and
/// what's happening to their file. Dashed until made, solid once it is.
private struct VersionCard: View {
    let version: PlannedVersion
    let titleCard: Bool
    let ring: RingColour
    let state: PeopleVersionsModel.RowState

    private var mark: StatusMark {
        if case .made = state { return .accepted }
        return .proposed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            TitleCardPreview(headline: titleCard ? version.headline : version.recipient.name,
                             subline: titleCard ? version.subline : "", ring: ring)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(version.recipient.name).textStyle(.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.xs)
                stateView
            }
        }
        .padding(Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
        .statusOutline(mark, cornerRadius: Theme.Radius.lg)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if !version.recipient.company.isEmpty { parts.append(version.recipient.company) }
        if let language = version.captionLanguage { parts.append("captions in \(language.name)") }
        if parts.isEmpty { parts.append(version.fileName) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var stateView: some View {
        switch state {
        case .ready: EmptyView()
        case let .making(progress):
            ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).tint(Theme.text)
        case let .made(url):
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
        case let .failed(message):
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.error)
                .help(message)
                .accessibilityLabel("Didn't make it: \(message)")
        }
    }
}

/// The personalised card as the export draws it: the brand ring, the
/// first line large, the second under it, on the brand's paper.
struct TitleCardPreview: View {
    let headline: String
    let subline: String
    let ring: RingColour

    var body: some View {
        GeometryReader { geo in
            let short = min(geo.size.width, geo.size.height)
            VStack(alignment: .leading, spacing: short * 0.03) {
                Circle()
                    .strokeBorder(Color(hex: ring.hex), lineWidth: short * 0.022)
                    .frame(width: short * 0.18, height: short * 0.18)
                Text(headline)
                    .font(.system(size: short * 0.09, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !subline.isEmpty {
                    Text(subline)
                        .font(.system(size: short * 0.045))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, geo.size.width * 0.08)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color(hex: BrandStore.shared.kit.paperHex))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.line))
        .accessibilityLabel("Title card: \(headline). \(subline)")
    }
}

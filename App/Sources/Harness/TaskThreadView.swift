import AppKit
import SwiftUI
import VisionOneKit

/// One task's thread: the take, then each ask with the agent's plan,
/// live status, approvals and receipts, and the composer at the bottom.
struct TaskThreadView: View {
    @ObservedObject var model: HarnessModel
    let take: Take

    private var cells: [ThreadCell] {
        TaskThread.cells(for: take, jobs: model.jobs(for: take), queued: model.queued[take.name] ?? [])
    }

    var body: some View {
        let cells = self.cells
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                        ForEach(cells) { cell in
                            ThreadCellView(cell: cell, model: model, take: take)
                                .id(cell.id)
                        }
                        if cells.count == 1 { firstSteps }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.lg)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: cells.map(\.id)) { _, _ in
                    withAnimation(Theme.Motion.enter) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Composer(model: model)
                .frame(maxWidth: 720)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.bottom, Theme.Space.md)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
    }

    /// Before any agent has run: the asks most people start with, dashed
    /// because they're only suggestions.
    private var firstSteps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Try").textStyle(.label).foregroundStyle(Theme.textFaint)
            FlowChips(chips: ["Make it 60 seconds", "/clips 3", "/captions", "/share Version One"]) { chip in
                model.send(chip)
            }
        }
    }
}

/// Dashed starter chips: tap to send.
struct FlowChips: View {
    let chips: [String]
    let tap: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) { items }
            VStack(alignment: .leading, spacing: Theme.Space.sm) { items }
        }
    }

    private var items: some View {
        ForEach(chips, id: \.self) { chip in
            Button(chip) { tap(chip) }
                .buttonStyle(DashedChipStyle())
        }
    }
}

/// Dashed means proposed: these are only suggestions until you pick one.
struct DashedChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.label)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.md - 4)
            .frame(height: Theme.Size.control)
            .background(configuration.isPressed ? Theme.canvas : Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: Theme.Stroke.hairline,
                                                                           dash: Theme.Stroke.dash)))
            .contentShape(Capsule())
    }
}

/// "What should we make in RankRide launch?" with starters and the
/// composer. Typing something with nothing recorded keeps it for the
/// next take.
struct NewTaskView: View {
    @ObservedObject var model: HarnessModel

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: Theme.Space.xl)
            Text("What should we make\(projectSuffix)?")
                .textStyle(.display)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            FlowChips(chips: ["/record a launch demo", "Clips from my last video", "/copy a video's style",
                              "Write this week's update"]) { chip in
                start(chip)
            }
            if !model.nextTakeAsks.isEmpty {
                Notice(.info, lead: "Saved for your next recording",
                       detail: model.nextTakeAsks.joined(separator: " · "))
                    .frame(maxWidth: 560)
            }
            Composer(model: model, placeholder: "Describe a video, or press record")
                .frame(maxWidth: 640)
            Spacer(minLength: Theme.Space.xl)
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private var projectSuffix: String {
        guard model.project != ProjectBook.defaultID, let project = model.book.project(model.project) else { return "" }
        return " in \(project.name)"
    }

    private func start(_ chip: String) {
        switch chip {
        case "Clips from my last video":
            guard let newest = model.takes.first else { return }
            model.open(newest)
            model.send("/clips 3")
        case "Write this week's update":
            model.draft = "/record this week's update: "
            model.focusComposer += 1
        default:
            model.send(chip)
        }
    }
}

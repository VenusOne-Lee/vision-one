import AppKit
import SwiftUI
import VisionOneKit

/// One task's thread from the Desk: takes, asks, plans, replies,
/// receipts and approvals, the live status line and the queue, with the
/// composer at the bottom.
struct TaskThreadView: View {
    @ObservedObject var model: HarnessModel
    let task: DeskTask

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                        ForEach(task.cells) { cell in
                            ThreadCellView(cell: cell, task: task, model: model)
                                .id(cell.id)
                        }
                        if task.cells.count <= 2, task.take != nil { firstSteps }
                        StatusCell(snapshot: model.snapshot, task: task) { model.stopRunning() }
                        if !task.queued.isEmpty {
                            QueuedCell(asks: task.queued) { model.editQueued(at: $0, to: nil) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.lg)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: task.cells.count) { _, _ in
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
            FlowChips(chips: ["/record", "Clips from my last video", "/style",
                              "Write this week's update"]) { chip in
                start(chip)
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
        guard let project = model.currentProject else { return "" }
        return " in \(project.name)"
    }

    private func start(_ chip: String) {
        switch chip {
        case "Clips from my last video":
            guard let newest = model.takes.first else { return }
            model.open(newest)
            model.send("/clips 3")
        case "Write this week's update":
            model.send("/script what's new this week")
        default:
            model.send(chip)
        }
    }
}

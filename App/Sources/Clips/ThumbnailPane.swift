import AppKit
import SwiftUI
import VisionOneKit

/// The Thumbnail tab: the thumbnail as it will be saved, with the title
/// and camera bubble draggable on it, five suggested frames underneath,
/// and the title, sizes and save beside them.
struct ThumbnailPane: View {
    @ObservedObject var model: ThumbnailModel

    @State private var title = ""
    @State private var titleDrag: CGPoint?
    @State private var faceDrag: CGPoint?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if let design = model.design {
                    canvas(design)
                    frames(design)
                    titleField
                    sizes(design)
                    tuning(design)
                    saveRow
                } else if model.phase == .finding {
                    ProgressView("Finding good frames…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    EditorNotice(title: "No frames yet",
                                 message: "Vision One picks thumbnail frames from what the editor kept. Once there's video to show, they appear here.",
                                 isError: false)
                }
            }
            .padding(14)
        }
        .background(Theme.paper)
        .onAppear { title = model.design?.title ?? "" }
        .onChange(of: model.design?.title) { _, new in
            if let new, new != title { title = new }
        }
    }

    // MARK: Canvas

    private func canvas(_ design: ThumbnailDesign) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if design.sizes.count > 1 {
                Picker("Preview", selection: $model.previewSize) {
                    ForEach(design.sizes) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.previewSize) { _, _ in model.refresh() }
            }
            stage(design)
        }
    }

    private func stage(_ design: ThumbnailDesign) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(Theme.canvas)
                    ProgressView().controlSize(.small).frame(width: size.width, height: size.height)
                }
                if let layout = model.layout {
                    handle(layout.title, in: size, label: "Drag the title")
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = titleDrag ?? CGPoint(x: design.titleX, y: design.titleY)
                                titleDrag = start
                                model.moveTitle(x: start.x + value.translation.width / size.width,
                                                y: start.y + value.translation.height / size.height)
                            }
                            .onEnded { _ in titleDrag = nil })
                    if let face = layout.face {
                        handle(face, in: size, label: "Drag the camera bubble", circle: true)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let start = faceDrag ?? CGPoint(x: design.faceX, y: design.faceY)
                                    faceDrag = start
                                    model.moveFace(x: start.x + value.translation.width / size.width,
                                                   y: start.y + value.translation.height / size.height)
                                }
                                .onEnded { _ in faceDrag = nil })
                    }
                }
            }
        }
        .aspectRatio(CGFloat(model.previewSize.aspect), contentMode: .fit)
        .frame(maxHeight: model.previewSize == .cover ? 420 : nil)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .frame(maxWidth: .infinity)
    }

    /// A dashed outline over something draggable, shown on hover.
    private func handle(_ rect: NormalizedRect, in size: CGSize, label: String, circle: Bool = false) -> some View {
        HoverOutline(circle: circle)
            .frame(width: CGFloat(rect.width) * size.width, height: CGFloat(rect.height) * size.height)
            .offset(x: CGFloat(rect.x) * size.width, y: CGFloat(rect.y) * size.height)
            .help(label)
            .accessibilityLabel(label)
    }

    // MARK: Frames

    private func frames(_ design: ThumbnailDesign) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SUGGESTED FRAMES")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if model.phase == .finding { ProgressView().controlSize(.mini) }
                Button("Find again") { Task { await model.findFrames() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .disabled(model.phase == .finding)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                ForEach(model.candidates) { candidate in
                    let isOn = abs(candidate.metrics.time - design.time) < 0.05
                    Button { model.choose(candidate.metrics.time) } label: {
                        Image(decorative: candidate.image, scale: 1)
                            .resizable()
                            .aspectRatio(16.0 / 9.0, contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(isOn ? Theme.text : Theme.textMuted,
                                              style: StrokeStyle(lineWidth: isOn ? 2 : 1, dash: isOn ? [] : [3, 3])))
                            .overlay(alignment: .bottomLeading) {
                                Text(Timecode.string(from: candidate.metrics.time))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                                    .padding(3)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(why(candidate.metrics))
                    .accessibilityLabel("Frame at \(Timecode.string(from: candidate.metrics.time))")
                }
            }
        }
    }

    private func why(_ m: ThumbnailPicker.Metrics) -> String {
        var parts = ["sharpness \(String(format: "%.2f", m.sharpness))"]
        if let face = m.faceQuality { parts.append("face \(String(format: "%.2f", face))") }
        if m.distanceFromCut.isFinite { parts.append(String(format: "%.1f s from a cut", m.distanceFromCut)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TITLE")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            TextField("Three to six big words", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setTitle(title) }
                .onChange(of: title) { _, new in model.setTitle(new) }
        }
    }

    private func sizes(_ design: ThumbnailDesign) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SIZES")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: 6) {
                ForEach(ThumbnailSize.allCases) { size in
                    let isOn = design.sizes.contains(size)
                    Button { model.toggle(size) } label: {
                        Text("\(size.title) \(size.pixels.width)×\(size.pixels.height)")
                            .font(.system(size: 11).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(isOn ? Theme.text : Theme.textMuted,
                                                            style: StrokeStyle(lineWidth: 1, dash: isOn ? [] : [3, 2])))
                            .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    private func tuning(_ design: ThumbnailDesign) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Title width").font(.system(size: 12)).frame(width: 84, alignment: .leading)
                Slider(value: Binding(get: { design.titleWidth }, set: { model.setTitleWidth($0) }), in: 0.2...0.95)
            }
            Toggle("Camera bubble", isOn: Binding(get: { design.showFace }, set: { model.setShowFace($0) }))
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .disabled(!model.hasCamera)
                .help(model.hasCamera ? "Show your camera in your ring" : "This take has no camera")
            if design.showFace && model.hasCamera {
                HStack {
                    Text("Bubble size").font(.system(size: 12)).frame(width: 84, alignment: .leading)
                    Slider(value: Binding(get: { design.faceSize }, set: { model.setFaceSize($0) }), in: 0.15...0.8)
                }
            }
        }
    }

    private var saveRow: some View {
        HStack(spacing: Theme.Space.sm) {
            switch model.phase {
            case .saving:
                ProgressView().controlSize(.small)
            case let .saved(urls):
                ExportRing(progress: 1)
                Button("Show \(urls.count == 1 ? "thumbnail" : "\(urls.count) thumbnails")") { model.reveal() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            case let .failed(message):
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.error).lineLimit(2)
            default:
                EmptyView()
            }
            Spacer()
            Button("Save thumbnails") { model.save() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(model.phase == .saving)
        }
    }
}

/// A dashed outline that appears on hover over a draggable part.
private struct HoverOutline: View {
    let circle: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if circle {
                Circle().strokeBorder(Color.white.opacity(hovering ? 0.9 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(hovering ? 0.9 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }
}

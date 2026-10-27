import AVFoundation
import Combine
import VisionOneKit

/// The take's zooms (zooms.json) and blurs (blurs.json) while it's open in
/// the editor. Changes share the editor's undo stack and are saved
/// straight away. The first time a take is opened, auto zoom plans from
/// the click log and the secret scan runs in the background; what they
/// find arrives dashed, for the user to accept.
@MainActor
final class EffectsModel: ObservableObject {
    enum ScanState: Equatable {
        case idle
        case scanning(Double)
        case done(found: Int)
        case failed(String)
    }

    let take: Take
    private let undoManager: UndoManager

    @Published private(set) var zooms = ZoomList()
    @Published private(set) var blurs = BlurList()
    @Published private(set) var scan: ScanState = .idle
    /// Shows the whole frame with the zoom and blur boxes on top, so they
    /// can be dragged and resized. Off plays the edit as it will export.
    @Published var isAdjusting = false {
        didSet { if isAdjusting != oldValue { onChange?() } }
    }
    @Published private(set) var error: String?
    /// The take has a click log, so auto zoom has something to go on.
    @Published private(set) var hasClickLog = false
    @Published private(set) var clickCount = 0

    /// Called after every change, so the preview can redraw.
    var onChange: (() -> Void)?

    private(set) var cursor: [CursorPoint] = []
    private var events: EventLog?
    private var scanTask: Task<Void, Never>?

    init(take: Take, undoManager: UndoManager) {
        self.take = take
        self.undoManager = undoManager
    }

    // MARK: Loading

    /// Reads both files. A take opened for the first time gets proposals.
    func load(edits: EditList) {
        if let log = try? EventLog.read(from: take.eventsURL) {
            events = log
            cursor = log.cursorPath
            clickCount = log.clicks.count
            hasClickLog = true
        }
        let fm = FileManager.default
        let firstZooms = !fm.fileExists(atPath: take.zoomsURL.path)
        let firstBlurs = !fm.fileExists(atPath: take.blursURL.path)
        do {
            zooms = try ZoomList.load(from: take.zoomsURL)
            blurs = try BlurList.load(from: take.blursURL)
        } catch {
            self.error = "Couldn't read this take's zooms or blurs: \(error.localizedDescription)"
            return
        }
        if firstZooms, hasClickLog {
            var next = zooms
            next.propose(plannedZooms(energy: next.energy, edits: edits))
            zooms = next
            save(zooms: true, blurs: false)
        }
        if firstBlurs {
            findSecrets()
        }
        onChange?()
    }

    func close() {
        scanTask?.cancel()
    }

    // MARK: Auto zoom

    private func plannedZooms(energy: ZoomEnergy, edits: EditList) -> [Zoom] {
        guard let events else { return [] }
        return ZoomPlanner.propose(from: events, style: .energy(energy),
                                   sourceDuration: edits.sourceDuration, removed: edits.removedSpans)
    }

    /// Re-plans from the clicks at an energy. Unanswered proposals are
    /// replaced; accepted and rejected zooms stay as they are.
    func findZooms(energy: ZoomEnergy, edits: EditList) {
        var next = zooms
        next.energy = energy
        next.clearProposals()
        next.propose(plannedZooms(energy: energy, edits: edits))
        apply(zooms: next, actionName: "Find Zooms")
    }

    /// A zoom on the cursor (or the middle) for three seconds from `t`.
    func addZoom(at t: Double, sourceDuration: Double) {
        let point = cursorPosition(at: t) ?? (0.5, 0.5)
        let span = TimeSpan(start: t, end: min(sourceDuration, t + 3))
        guard span.duration > 0.5 else { return }
        var next = zooms
        next.zooms.removeAll { $0.span.overlaps(span) && $0.state == .rejected }
        next.zooms.append(Zoom(span: span, scale: ZoomStyle.energy(zooms.energy).scale,
                               centerX: point.0, centerY: point.1, reason: Zoom.Reason.manual, state: .accepted))
        apply(zooms: next, actionName: "Add Zoom")
        isAdjusting = true
    }

    /// A zoom on a box drawn over the video (with the Zoom tool, a pen
    /// circle or by voice), for `span`.
    func addZoom(span: TimeSpan, viewport: FrameRect, state: ProposalState = .accepted,
                 actionName: String = "Add Zoom") {
        var zoom = Zoom(span: span, scale: 2, centerX: viewport.midX, centerY: viewport.midY,
                        reason: Zoom.Reason.manual, state: state)
        zoom.setViewport(viewport)
        var next = zooms
        next.zooms.removeAll { $0.span.overlaps(span) && $0.state == .rejected }
        next.zooms.append(zoom)
        apply(zooms: next, actionName: actionName)
    }

    func setZoom(_ zoom: Zoom, actionName: String = "Adjust Zoom") {
        var next = zooms
        next.update(zoom)
        apply(zooms: next, actionName: actionName)
    }

    func setZoomState(_ state: ProposalState, for id: UUID) {
        var next = zooms
        next.setState(state, for: id)
        apply(zooms: next, actionName: state == .accepted ? "Accept Zoom" : "Turn Off Zoom")
    }

    func removeZoom(_ id: UUID) {
        var next = zooms
        next.remove(id: id)
        apply(zooms: next, actionName: "Delete Zoom")
    }

    private func cursorPosition(at t: Double) -> (Double, Double)? {
        guard let point = cursor.last(where: { $0.t <= t }) ?? cursor.first else { return nil }
        return (point.x, point.y)
    }

    // MARK: Secret blur

    /// Reads the text on screen and proposes blurs over anything secret.
    func findSecrets() {
        scanTask?.cancel()
        scan = .scanning(0)
        let take = take
        scanTask = Task { [weak self] in
            do {
                let found = try await SecretFinder.scan(take) { progress in
                    guard let self, case .scanning = self.scan else { return }
                    self.scan = .scanning(progress)
                }
                guard let self, !Task.isCancelled else { return }
                var next = self.blurs
                let added = next.propose(found)
                // Saved even when nothing was found, so the scan doesn't
                // run again every time the take opens.
                self.apply(blurs: next, actionName: "Find Secrets")
                self.scan = .done(found: added.count)
            } catch is CancellationError {
                self?.scan = .idle
            } catch {
                self?.scan = .failed("Couldn't read the screen text: \(error.localizedDescription)")
            }
        }
    }

    /// A blur box in the middle of the frame for three seconds from `t`,
    /// ready to drag over what needs hiding.
    func addBlur(at t: Double, sourceDuration: Double) {
        let span = TimeSpan(start: t, end: min(sourceDuration, t + 3))
        guard span.duration > 0.2 else { return }
        var next = blurs
        next.add(Blur(span: span, rect: FrameRect(x: 0.35, y: 0.45, width: 0.3, height: 0.08),
                      kind: nil, reason: Blur.Reason.manual, state: .accepted))
        apply(blurs: next, actionName: "Add Blur")
        isAdjusting = true
    }

    /// A blur over a box drawn on the video, for `span`.
    func addBlur(span: TimeSpan, rect: FrameRect, state: ProposalState = .accepted,
                 actionName: String = "Add Blur") {
        var next = blurs
        next.add(Blur(span: span, rect: rect.clamped, kind: nil, reason: Blur.Reason.manual, state: state))
        apply(blurs: next, actionName: actionName)
    }

    func setBlur(_ blur: Blur, actionName: String = "Adjust Blur") {
        var next = blurs
        next.update(blur)
        apply(blurs: next, actionName: actionName)
    }

    func setBlurState(_ state: ProposalState, for id: UUID) {
        var next = blurs
        next.setState(state, for: id)
        apply(blurs: next, actionName: state == .accepted ? "Accept Blur" : "Turn Off Blur")
    }

    func removeBlur(_ id: UUID) {
        var next = blurs
        next.remove(id: id)
        apply(blurs: next, actionName: "Delete Blur")
    }

    // MARK: Both

    var proposedCount: Int { zooms.proposedCount + blurs.proposedCount }

    func acceptAllProposed() {
        var nextZooms = zooms
        nextZooms.acceptAllProposed()
        var nextBlurs = blurs
        nextBlurs.acceptAllProposed()
        apply(zooms: nextZooms, blurs: nextBlurs, actionName: "Accept All")
    }

    /// What the preview draws. While adjusting, the zoom is left out so
    /// the whole frame shows under the boxes.
    func previewEffects(edits: EditList) -> FrameEffects? {
        let effects = FrameEffects.preview(zooms: isAdjusting ? ZoomList() : zooms, blurs: blurs,
                                           cursor: cursor, edits: edits)
        return effects.isEmpty ? nil : effects
    }

    // MARK: Undo and saving

    /// Internal so the editor's Changes list can switch a whole group.
    func apply(zooms nextZooms: ZoomList? = nil, blurs nextBlurs: BlurList? = nil, actionName: String) {
        let previousZooms = zooms
        let previousBlurs = blurs
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.apply(zooms: previousZooms, blurs: previousBlurs, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        if let nextZooms { zooms = nextZooms }
        if let nextBlurs { blurs = nextBlurs }
        save(zooms: nextZooms != nil, blurs: nextBlurs != nil)
        onChange?()
    }

    /// Writes only the files that changed, so a take whose secret scan
    /// hasn't finished still has no blurs.json and scans again next time.
    private func save(zooms saveZooms: Bool, blurs saveBlurs: Bool) {
        do {
            if saveZooms { try zooms.write(to: take.zoomsURL) }
            if saveBlurs { try blurs.write(to: take.blursURL) }
            error = nil
        } catch {
            self.error = "Couldn't save zooms and blurs: \(error.localizedDescription)"
        }
    }
}

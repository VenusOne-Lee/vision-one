import AppKit
import SwiftUI
import VisionOneKit

/// The Producer's "before you record" checks, under Home's record button:
/// things to fix first, then tips. Rechecked when the window comes forward
/// or what's recorded changes. Talking points stay in the Producer window.
struct HomePreflight: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    @AppStorage(TakePlan.nextPurposeKey) private var purposeID = ""
    @State private var notes: [ProducerAgent.Note] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes.prefix(3)) { note in
                HStack(alignment: .top, spacing: 8) {
                    Text(note.level == .fix ? "FIX" : "TIP")
                        .font(.system(size: 10, weight: .bold)).tracking(0.6)
                        .foregroundStyle(note.level == .fix ? Theme.error : Theme.textMuted)
                        .frame(width: 26, alignment: .leading)
                        .padding(.top, 1)
                    Text(note.title)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(note.detail)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(note.level == .fix ? Theme.errorSoft : Theme.canvas,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            Button("Talking points…") { ProducerWindowController.shared.show() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .help("Ask the Producer for a hook and talking points before you record")
        }
        .frame(maxWidth: 280)
        .opacity(recorder.phase.isLive ? 0 : 1)
        .onAppear(perform: recheck)
        .onChange(of: recorder.choice) { _, _ in recheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in recheck() }
        .onChange(of: purposeID) { _, _ in recheck() }
    }

    private func recheck() {
        let fresh = ProducerAgent.check(ProducerModel.situation(purposeID: purposeID.isEmpty ? Purpose.demo.id : purposeID,
                                                                choice: recorder.choice))
        // Fixes first.
        let sorted = fresh.filter { $0.level == .fix } + fresh.filter { $0.level == .tip }
        if sorted != notes { notes = sorted }
    }
}

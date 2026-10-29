import Foundation
import VisionOneKit

/// Denied preflight must publish a window-visible explanation and keep the
/// failed board job, without launching an app, asking TCC or starting capture.
@MainActor
enum AutopilotPreflightVerification {
    static func run(in root: URL) async throws {
        let board = AgentJobBoard()
        var requests = 0
        let service = AutopilotService(board: board, accessibilityTrusted: { false },
                                      requestAccessibility: { requests += 1; return false })
        let demo = DemoScript(name: "Denied preflight fixture", app: DemoApp(bundleID: "com.apple.ActivityMonitor"),
                              steps: [DemoStep(.wait, seconds: 1)])
        let file = DemoFile(url: root.appendingPathComponent("denied-demo.json"), demo: demo)
        let id = service.run(file)
        var finished: AgentJob?
        for _ in 0..<500 {
            if let job = await board.job(id), job.state == .failed, !service.isBusy {
                finished = job
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let job = finished else { throw MediaVerification.Failure(message: "Autopilot denied preflight lost board failure") }
        try MediaVerification.require(requests == 1 && job.error == StopReason.noAccess.message,
                                      "Autopilot preflight reported the wrong failure")
        try MediaVerification.require(service.startProblem(for: demo) == job.error && !service.isBusy && service.running == nil,
                                      "Autopilot window lost failed-start feedback")
        try JSONSerialization.data(withJSONObject: ["failedBoardJobRetained": true, "windowProblemPublished": true,
                                                  "captureNotStarted": true, "realPermissionPromptUsed": false],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("autopilot-preflight.json"))
        print("Native Autopilot denied-preflight board/visible-feedback verification passed")
    }
}

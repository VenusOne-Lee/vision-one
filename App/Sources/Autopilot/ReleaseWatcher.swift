import Foundation
import VisionOneKit

/// Checks GitHub for new releases of the repos demos are tied to, when
/// Vision One opens and every hour, and re-records the demos that are due.
/// Public repos need no sign-in. GitHub's own Mac runners can't grant
/// Screen Recording, so this is how a release reaches the Mac by default;
/// the rerecord-demos Action is the other way, on a self-hosted runner.
@MainActor
final class ReleaseWatcher {
    static let shared = ReleaseWatcher()

    private var timer: Timer?

    func start() {
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: ReleaseWatch.interval, repeats: true) { _ in
            Task { @MainActor in ReleaseWatcher.shared.check() }
        }
    }

    func check() {
        Task { await checkNow() }
    }

    func checkNow() async {
        let service = AutopilotService.shared
        let demos = service.library.all()
        let repos = ReleaseWatch.repos(in: demos)
        guard !repos.isEmpty else { return }
        var latest: [String: GitHubRelease] = [:]
        for repo in repos {
            if let release = await Self.fetchLatest(repo) { latest[repo] = release }
        }
        service.setBaseline(ReleaseWatch.baseline(demos, latest: latest, state: service.state))
        var lastRuns: [String: AutopilotRun] = [:]
        for file in demos {
            if let run = service.lastRun(of: file.demo) { lastRuns[file.demo.slug] = run }
        }
        for plan in ReleaseWatch.due(demos, latest: latest, state: service.state, lastRuns: lastRuns) {
            service.rerecord(plan)
        }
    }

    private static func fetchLatest(_ repo: String) async -> GitHubRelease? {
        guard let url = GitHubRelease.latestURL(for: repo) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vision One", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? GitHubRelease.decode(reply.0)
    }
}

import AppKit
import VisionOneKit

// `Vision One --mcp` is how Claude Code, Codex and other agents start
// Vision One's MCP server: a small bridge between their stdin/stdout and
// the running app, which it opens in the background if needed. Anything
// else is the app itself.
if CommandLine.arguments.contains("--mcp") {
    let bundle = Bundle.main.bundleURL
    let code = MCPBridge.run(openApp: {
        // Already running (maybe another copy) with agents off: don't
        // start a second Vision One, just say so.
        let id = Bundle.main.bundleIdentifier ?? ""
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != getpid() }
        if running { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", bundle.path, "--args", MCPService.backgroundFlag]
        do {
            try open.run()
            open.waitUntilExit()
            return true
        } catch {
            return false
        }
    })
    exit(code)
} else {
    MainActor.assumeIsolated {
        // Opened by an agent: no Dock icon until the person opens a window.
        if CommandLine.arguments.contains(MCPService.backgroundFlag) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        VisionOneApp.main()
    }
}

import AppKit
import VisionOneKit

// `Vision One --mcp` is how Claude Code, Codex and other agents start
// Vision One's MCP server: a small bridge between their stdin/stdout and
// the running app, which it opens in the background if needed. Anything
// else is the app itself.
if CommandLine.arguments.contains("--mcp") {
    let bundle = Bundle.main.bundleURL
    let code = MCPBridge.run(openApp: {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", bundle.path, "--args", MCPService.backgroundFlag]
        try? open.run()
    })
    exit(code)
} else {
    MainActor.assumeIsolated {
        VisionOneApp.main()
    }
}

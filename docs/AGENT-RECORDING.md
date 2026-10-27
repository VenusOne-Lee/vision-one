# Recording an AI agent

Vision One can record Claude, Codex or any computer-use agent while it uses your Mac. The take is a normal take. On top of that, the agent's clicks and typing are marked, its notes become chapters, and the long waits while it thinks are proposed as cuts.

Visual overview: https://claude.ai/artifact/X863ny5CUCPNxB52GfbsTQ

## Three ways to start

- **The agent asks over MCP.** It calls `start_agent_recording` (`task`, optional `app` to record only that app's window, optional `title`). Vision One shows the approval card: *Record Claude Code using your Mac?* It answers Allow once, Allow until quit or Don't allow, the same as `start_recording`. Then the agent calls `log_step` with a few words before each part ("Open the pricing page"), and `stop_recording` when it's done.
- **You pick File › Record an Agent…** For agents that don't use MCP. It counts down like any take, so there's time to start the agent.
- **Vision One offers.** When a known agent app (Claude, ChatGPT, Codex, Cursor, Perplexity, cliclick) starts clicking or typing, Vision One shows the card: *Claude is using your Mac. Record it?* Other apps never set this off. You can turn it off in **Settings › Agents › Offer to record when an agent uses this Mac**.

While recording, the REC bar shows the orange live dot as always, plus *Claude Code is driving*.

## How Vision One tells the agent from you

Every macOS input event carries the id of the process that posted it (`kCGEventSourceUnixProcessID`). The keyboard, mouse and trackpad show 0. Events posted by an app (`CGEventPost`) show that app's id. Vision One keeps only posted events, so **your own clicks and typing are never logged**. Autopilot's events carry Vision One's tag (`eventSourceUserData`) and are never counted as an outside agent. (`InputOrigin` in `Sources/VisionOneKit/AgentRecording/AgentInput.swift`.)

Agents that drive a browser from inside (Claude in Chrome, Playwright or Puppeteer over the DevTools Protocol) click inside the page, and the Mac never sees those events. Their `log_step` notes are the record of those steps. The video still shows the page change.

- Mouse events need no permission. Seeing the agent's typing needs Accessibility, which Autopilot also asks for. Without it, only clicks are marked.
- Typing while macOS secure input is on (a password field) is saved as *Typed a password (hidden)*, with no text.
- Text that looks like a key, token or card number is masked with `SecretScanner`, the same scanner that blurs secrets on screen.
- An agent can't approve its own requests. A yes on the floating approval card or on the card in a task's thread only counts from the real keyboard, mouse or trackpad. A posted click on Allow just beeps. (`PersonInput` in `App/Sources/AgentRecording/AgentSession.swift`.)

## actions.json

This file sits in the take folder next to `events.json`. Times are seconds from the first video frame. Positions are in points from the top left of what was recorded.

```json
{
  "version": 1,
  "agent": "Claude Code",
  "task": "Sign up on staging",
  "startedAt": "2026-10-27T16:40:00Z",
  "actions": [
    { "kind": "step", "source": "told", "t": 0.8, "text": "Open the signup page" },
    { "kind": "click", "source": "seen", "t": 2.1, "x": 612, "y": 340, "app": "Safari" },
    { "kind": "type", "source": "seen", "t": 3.0, "end": 4.6, "text": "lee+test@versionone.co.za", "app": "Safari" },
    { "kind": "type", "source": "seen", "t": 5.2, "end": 6.0, "hidden": true, "app": "Safari" },
    { "kind": "key", "source": "seen", "t": 6.3, "text": "Return", "app": "Safari" }
  ]
}
```

Kinds: `click`, `doubleClick`, `rightClick`, `drag`, `scroll` (text is the direction), `type`, `key` (`Return`, `⌘C`), `step` (the agent's note). `AgentActionRecorder` groups the raw events. A down and an up make a click, or a drag past 8 points. Keys less than 2 s apart make one *Typed …*, and backspace fixes that typing instead of adding a step. Scroll events less than 0.6 s apart make one scroll.

## Skip the waiting

After transcribing, Vision One looks for gaps over 4 s with no action and no speech. It proposes a dashed cut for each one, reason `agentWaiting`. Each cut keeps 1.5 s after the last action, so its result shows, and 0.8 s before the next one. A take with no marked actions gets no cuts. Running it again never repeats a cut or brings back one you turned down. Over MCP, `stop_recording` reports these cuts on its task, so `keep_changes` with that `task_id` keeps them, after you say yes.

## Code

- Kit: `Sources/VisionOneKit/AgentRecording/` (`AgentAction`, `AgentActionLog`, `InputOrigin`, `AgentApps`, `AgentTakeoverDetector`, `AgentActionRecorder`, `AgentWaiting`). Tests are in `AgentRecordingTests.swift` and `MCPTests.swift`.
- App: `App/Sources/AgentRecording/AgentSession.swift` (the event monitor, `AgentProcess`, `PersonInput`) and `AgentWatcher.swift` (the offer). `ScreenRecorder.start(choosing:)` records an app's window without changing your saved choice.

## Not yet

- A step list beside the editor's timeline. The data is `AgentActionLog.sorted` and `.chapters`.
- Step captions burned into exports, and click rings drawn from the agent's clicks.
- Cloud agents running on another computer. Vision One records this Mac only.

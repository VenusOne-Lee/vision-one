# Vision One MCP server

Vision One is an MCP server, so Claude Code, Codex, Cursor, Claude Desktop or any MCP client can record, edit, clip, export and share with it. You stay in your coding agent ("record a short demo of the signup page, tidy it to 60 seconds and make a vertical clip") and approve the parts that matter inside Vision One.

Visual overview: https://claude.ai/artifact/AAUWHZZ89VoBXRFTRKdjB9

## Add it to your agent

The easy way: **Vision One › Settings › Agents › Add to Claude Code** (or **Add to Codex**). That runs the agent's own setup command for you. If the agent isn't found, the command goes on your clipboard to paste into Terminal.

By hand:

```sh
# Claude Code (all projects)
claude mcp add --scope user vision-one -- "/Applications/Vision One.app/Contents/MacOS/Vision One" --mcp

# Codex
codex mcp add vision-one -- "/Applications/Vision One.app/Contents/MacOS/Vision One" --mcp
```

Codex's `~/.codex/config.toml`:

```toml
[mcp_servers.vision-one]
command = "/Applications/Vision One.app/Contents/MacOS/Vision One"
args = ["--mcp"]
```

Cursor, Claude Desktop, Zed and other apps that take JSON (Settings › Agents › Copy setup for other apps):

```json
{
  "mcpServers": {
    "vision-one": {
      "command": "/Applications/Vision One.app/Contents/MacOS/Vision One",
      "args": ["--mcp"]
    }
  }
}
```

## How it works

```
your agent ──stdio──▶ Vision One --mcp ──Unix socket──▶ Vision One app (MCP server)
                       (the bridge)        your user only     tools · resources · approvals
```

- The agent starts `Vision One --mcp`. That's the app's own binary acting as a small bridge: it connects to the running app over `~/Library/Application Support/Vision One/mcp.sock` and passes messages both ways. If Vision One isn't running, the bridge opens it in the background and waits up to 8 seconds.
- The socket file is readable only by your Mac user (0600). There's no network port, so web pages can't reach it.
- Turning off **Let coding agents use Vision One** closes the socket. The bridge then answers every request with a plain error saying so.
- One server, one session per connected agent. Each session knows the agent's name from MCP `clientInfo` ("Claude Code", "Codex").
- Protocol: MCP 2025-11-25 (also accepts 2025-06-18, 2025-03-26 and 2024-11-05). It answers the newer `server/discover` probe with those versions, so 2026-07-28 clients fall back to `initialize`.
- The code: `Sources/VisionOneKit/MCP/` (protocol, tools, resources, approvals, socket, bridge; tested in `MCPTests.swift`) and `App/Sources/MCP/` (the app host, approval card, Settings pane). `App/Sources/main.swift` picks bridge or app.

## What agents can do

Name a take by its title, its folder name, or `latest` (the default).

| Tool | What it does | Asks you? |
| --- | --- | --- |
| `list_takes` | Search takes by words said, title or what they're for | No |
| `get_take` | Length, purpose, transcript status, cuts, clips, exports, tasks | No |
| `read_transcript` | Words with times; `~~cut~~`, `[proposed]` | No |
| `get_timeline` | Every cut, zoom and blur with a short name (`c3`, `z1`, `b2`), times and state | No |
| `what_changed` | What changed in a take since this agent last looked, so it doesn't undo your edits | No |
| `list_tasks`, `wait_for_task` | What agents are doing; wait up to 45 s for one | No |
| `recording_status` | Recording or not, and which take | No |
| `start_recording` | Records with your last screen and sound choices | **Yes** |
| `stop_recording` | Stops, saves, transcribes on this Mac | No |
| `start_agent_recording` | Records the agent itself using the Mac: marks its clicks and typing, never yours ([AGENT-RECORDING.md](AGENT-RECORDING.md)) | **Yes** |
| `log_step` | During an agent recording: a short note that becomes a chapter | No |
| `clean_up` | Proposes cuts for ums, repeats, long pauses (on this Mac) | No, proposals |
| `cut_to_length` | The Editor agent proposes cuts to a length or an ask | No, proposals (AI settings may ask before words leave the Mac) |
| `cut_part` | Proposes cutting a quote or a time span; `plan: true` is a dry run showing the length before and after | No, proposals |
| `make_clips` | The Clipper agent proposes clips | No, proposals |
| `draft_posts` | The Sharer agent drafts title, chapters, posts | No, drafts |
| `keep_changes` | Makes a task's proposals count | **Yes** |
| `undo_changes` | Takes a task's proposals out | No |
| `write_captions` | `.srt` and `.vtt` of the kept video | No |
| `export_video` | MP4 with the brand kit: original, hd1080, hd720, whatsapp, vertical, square | No |
| `share_video` | Opens the post with the right export and the Sharer's words | **Yes, every time** |
| `rename_take` | Gives a take a title | No |
| `list_demos` | Autopilot demos: name, app, steps, about how long | No |
| `rerecord_demo` | Autopilot re-records a demo (optionally for a release); returns a `task_id` | **Yes**, unless you let those steps run on their own |

Resources: `visionone://takes`, `visionone://tasks`, `visionone://takes/{take}`, `visionone://takes/{take}/transcript`.

## Approvals and tasks

- Every call that does work becomes a task in the Agent Desk, tagged with the agent that asked ("from Claude Code"), filed under the take's task. Agent jobs started over MCP keep the id the tool hands back as `task_id`.
- Recording, keeping changes and sharing ask once. The question always sits on the task as a numbered card. With Vision One's main window in front, that card is the only place it asks. When the window is closed or you're in another app (your terminal, say), a floating card asks as well; it answers the same question, so answering either one closes both. The choices are **Allow once**, **Allow until quit** (not for shares) and **Don't allow**, with an optional note that goes back to the agent ("record the browser window, not the whole screen"), from either place. `VisionOneMCPHost.showsCard(for:)` makes the call; hosts without a window always show the floating card.
- Settings › Agents lists the agents that have connected. Each can be **Ask first** (the default) or **Allow until quit**. Sharing always asks.
- Edits are proposals (dashed) until kept. Exports only include kept cuts, so an agent calls `keep_changes` first, and you say yes.

## Long jobs

Codex gives a tool 60 seconds and Claude Code a similar limit. Tools answer within about 40 seconds. If a job is still running (an export, a long AI edit), the reply says so and carries a `task_id`; `wait_for_task` picks it up.

## Trying it without an agent

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"terminal"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_takes","arguments":{}}}' \
  | "/Applications/Vision One.app/Contents/MacOS/Vision One" --mcp
```

Or `npx @modelcontextprotocol/inspector "/Applications/Vision One.app/Contents/MacOS/Vision One" --mcp`.

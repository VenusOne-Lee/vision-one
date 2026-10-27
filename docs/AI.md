# AI ladder and agents

Vision One's AI runs on the cheapest rung that can do the job, and nothing leaves the Mac without the user saying yes. All of it lives in `Sources/VisionOneKit/AI/` so the app, other features and (later) the Vision One MCP server call the same code.

## The ladder

| Rung | Provider | Cost | Leaves the Mac | Good for |
| --- | --- | --- | --- | --- |
| 1 | Apple Foundation Models (`AppleOnDevice.provider()`, macOS 26 + Apple Intelligence) | R0 | No | Short jobs: titles, outlines, yes/no per sentence in batches. 4,096-token window. |
| 2 | Sign in with ChatGPT (`OpenAIResponsesProvider.chatGPT`) | From the user's Go, Plus or Pro plan | Yes | Agents that read the whole transcript: posts, chapters, clip titles. |
| 3 | OpenAI Decisions API (`OpenAIDecisionsProvider`, gpt-6-luna) | $0.10 per million input tokens, no output charge | Yes | Keep/cut and clip scores: up to 400 questions a request, about 10x faster than Responses. |
| 4 | Your own key: OpenAI, Claude (`AnthropicProvider`), OpenRouter or a local server (`OpenAICompatibleProvider`) | Your key's price | Yes, except a local server | Anything; pick per job in Settings. |

**Does ChatGPT plan usage cover the Decisions API? No** (checked 27 Oct 2026). OpenAI's plan-usage docs name only the Responses API (`POST /v1/responses`, with `store: false` and `stream: true`); the Decisions API docs only show API-key auth. So rung 3 needs an OpenAI key. Without one, keep/cut questions go to rung 1 or 2 through `DecisionEmulator`, which asks the same questions as JSON.

Image generation isn't covered by plan usage either, so thumbnails need an OpenAI key.

### How a job is routed (`AILadder`)

1. Providers are tried in the user's order (`AISettings.order`, cheapest first by default). Switched-off ones and, with "On this Mac only", every cloud rung are skipped. A job can be pinned to one provider (`taskProviders`).
2. Decision jobs (`ladder.decide`) try a native Decisions provider first when it's set up (`preferDecisionsAPI`).
3. A rung is skipped when the job won't fit its context window, or when it isn't ready (signed out, no key, Apple Intelligence off).
4. Before a cloud call, `OutboundGate` shows the approval sheet: what is sent, where, and the cost in rand (R0 "from your ChatGPT plan" on rung 2). "Allow for this session" stops it asking again for that provider and job until the app quits.
5. Usage limits, outages and too-long replies fall through to the next rung. **A "no" stops the job**: it is never quietly sent somewhere else.

Posts (to Version One, X, LinkedIn) go through the same gate as `.post` and are approved one at a time; "Allow for this session" never covers them.

### Calling it from another feature

```swift
let reply = try await ladder.complete(AIRequest(
    task: AITask("zoom.pick"), summary: "Pick moments to zoom",
    instructions: "...", input: transcriptText, format: .json(shape: #"[{"start": 1.0}]"#)))
let picks = try reply.decode([ZoomPick].self)

let result = try await ladder.decide(DecisionRequest(task: AITask("music.mood"), summary: "Pick a music mood",
    input: context, questions: [.choice("mood", "Which mood fits?", choices)]))
```

Keep each decision question self-contained: small rungs get them in batches.

## Sign in with ChatGPT

`ChatGPTAuth` and `ChatGPTSession` follow OpenAI's open source, runs-locally flow: system browser, loopback callback on `http://127.0.0.1:<port>/auth/callback`, PKCE (S256), no client secret. The first sign-in registers this Mac with `client_id=dynamic_agent_client`, a kept `ext_agent_host_id` (`urn:uuid:…`) and `agent_name_hint=Vision One`; the issued client id is saved and reused. Scopes: `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, resource `https://api.openai.com/v1`. Plan usage needs the `chatgpt.tokens.use.direct` scope in the token response; sign-in alone isn't enough. Tokens live in the Keychain (`AISecretStore`), never in a take folder.

## Agents

| Agent | What it does | Rungs |
| --- | --- | --- |
| Producer (`ProducerAgent`) | Pre-flight checks before recording (mic, disk, battery, notifications, camera for talking heads) as plain rules; optional outline: hook, points, payoff, call to action. | Checks: none. Outline: any, fits on device. |
| Editor (`EditorAgent`) | After auto-clean, one "keep this sentence?" question per sentence. With a length ("make it 60s") it drops the weakest until it fits; otherwise it drops ones under the Energy's threshold. Cuts are proposed (dashed) with reason `trim`. | Decisions API first, else any. |
| Clipper (`ClipperAgent`) | Scores candidate windows (from the clips feature's ClipFinder, or 15 to 60 s of whole sentences), keeps the best that don't overlap, titles them. Picks become proposed `Clip`s with origin `agent` in clips.json, so they show dashed in the editor's Clips tab. | Scores: Decisions first. Titles: any. |
| Sharer (`SharerAgent`) | Title, description, chapters (timed on the edited video), one post per network and a Version One launch draft matching `share_launch`. Saved as `share.json`; posting asks each time. | Any; usually rung 2. |

## Agent jobs (the Agent Desk)

Every agent run is an `AgentJob` on the `AgentJobBoard` (`Sources/VisionOneKit/AI/Jobs/`), the list behind the Agent Desk's tasks and the after-Stop cards. A job has an agent, a title, its take, the user's ask, a state (queued, running, needsApproval, needsReview, done, undone, failed, cancelled), steps with their own state, a one-line receipt ("Cut 21 s across 3 parts."), the changes it wrote (cut and clip ids, share.json) and any approval waiting on it. `statusLine` reads "Clipper · running, step 3 of 5".

- **Start:** `AgentRunner(board:ladder:)` has `edit`, `clips` and `share`; `afterRecording(_:plan:brief:)` starts them once a take is transcribed. The Energy dial decides how much is automatic: Calm runs only the Editor, Lively adds the Sharer, Viral (and Shorts) add the Clipper. Settings → AI can turn this off.
- **Approvals:** inside a job, the gate parks the request on the task (`needsApproval`, with what is sent, where and the cost) until `resolveApproval(jobID:decision:)`. A "no" cancels the job. Until the Agent Desk shows these cards, the floating panel asks as well and whichever answers first wins.
- **Keep and Undo:** `keep(_:)` makes the job's dashed cuts and clips solid; `undo(_:)` removes them and deletes its drafts.
- **Watching:** `updates()` is an `AsyncStream` of the list, current list first. `needsYou` is the "Needs you" filter. Jobs are saved to `~/Library/Application Support/Vision One/jobs.json` for 30 days; ones cut off by quitting come back as "didn't finish".

## The Desk (Codex-style projects and tasks)

`Desk` (`Sources/VisionOneKit/Desk/`) is the model behind the main window's sidebar, task threads and the menu bar's Tasks list. The app has one, `AIServices.shared.desk`; the MCP server calls the same methods.

- **Projects** (`DeskProject`): name, notes every agent reads (like AGENTS.md), a prompt preset, and `sources` the Producer reads for scripts (GitHub repos, Linear teams).
- **Tasks** (`DeskTask`): one per video. A thread of `TaskCell`s (ask, take, agent reply, quiet log, plan, receipt with Keep/Undo, numbered approval card, failure), queued asks, the mode (Just do it or Plan first) and the agent jobs it started. Stop makes one (`taskForRecording`); once transcribed, `transcribed(_:)` starts the automatic agents by the Energy dial.
- **Asking:** `submit(_:to:mode:)` routes the text through `AskRouter` (slash commands, or plain rules for "tighten the open and make 3 clips") into a `DeskPlan`. Just do it runs it now; Plan first shows the plan with a Yes/No card; while agents are busy the ask is queued and runs next. Commands the window handles itself (`/captions`, `/edit`, `/record`) come back as `.open`.
- **Approvals:** cards have numbered options with one preselected (`confirm` is Return). A job waiting on the gate shows "Yes, send it / Yes, and don't ask again for … in this project / No, and tell the agent what to do differently"; posts get Yes / No. "Don't ask again" lasts until the app quits for now.
- **Status:** `DeskSnapshot.status(of:)` is the ring (needs you, working, ready, done, didn't finish), `statusLine(of:)` the line under the title, `activity(of:)` the status bar ("Clipper is making clips (12 s · Esc to stop)"), `needsYou` the "2 need you" count. `stop` is Esc.
- **Try in a copy:** `TakeVersions` (versions.json) keeps the main cut in edits.json and copies beside it. `makeCopy`, `makeMain` (swaps files, the old main stays as a copy), `lock` on export. Plans with `inCopy`, or a locked main cut, run the Editor on a copy.
- **Scripts from your tools:** `ScriptSources` reads GitHub releases (token optional, for private repos) and Linear finished issues (API key), both from the Keychain. Only the repo or team name goes out. `ProducerAgent.script(from:brief:ask:)` turns them into a hook, lines and a call to action; the `/script` step posts it in the thread.
- **Watching:** `updates()` streams `DeskSnapshot`; `openRequests()` streams task ids the menu bar or a notification asked to open (`requestOpen`).

## Pick what it's for, and the Energy dial

`Purpose` is the "What are you making?" answer: launch, demo, short, tutorial, bugReport, update, talkingHead. Each sets a starting `Energy`, a target length and default prompts per part (hook, body, outro, title, post, chapters, clip, thumbnail). The look for each lives in the brand kit's `TemplateLook`, matched by the same id. `Purpose.brief(preset:variables:)` runs each part through the prompt presets' `PromptResolver` (your preset over these defaults, house style around it, `{product}`-style variables filled, plain words when the listing has none) and hands agents an `AgentBrief`.

`Energy` (Calm, Lively, Viral) gives one `EnergyProfile` that zooms, sound effects, captions and the Editor all read: zooms per minute, punch-ins, sound effects per minute, caption style, pause trimming (`CleanupSettings(energy:)`) and the Editor's keep threshold.

The take's choice is saved as `plan.json` (`TakePlan`).

## In the app

- **Menu bar → AI settings**: the ladder in the order it's tried (drag to change), a switch per rung, Sign in with ChatGPT, keys (kept in the Keychain), a local server, and "On this Mac only".
- **Menu bar → Before you record…**: pick what it's for, the Producer's pre-flight notes, and talking points.
- **Editor → Agents**: purpose, prompt preset and Energy for this take, the Editor's ask bar ("make it 60s"), Find clips, and Write title and posts. Editor cuts appear dashed in the transcript and timeline, like auto-clean's.
- **Approval panel**: floats over everything (and is hidden from recordings) whenever a job or post would leave the Mac. Send once, Allow for this session, or Don't send.
- Code: `App/Sources/AI/` (`AIServices` builds the ladder from settings and keys; other features call `AIServices.shared.ladder()`).

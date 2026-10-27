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

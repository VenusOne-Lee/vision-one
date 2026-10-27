# Vision One

A free, open source Mac screen recorder that edits itself. Record, pick what it's for, export. The AI runs on your Mac, so it costs nothing to run and your audio never leaves the device.

Made for South African builders, as the sibling of [Version One](https://versionone.co.za).

> **Status: v1 is coming together on main.** Vision One opens on a New task page in one window laid out like a coding agent: projects and tasks on the left, a task thread in the middle where the Producer plans and agents work, and a panel on the right that swaps between Video, Changes, Clips, Sound and Post. Record from anywhere (⇧⌘R); stopping files the take as a new task. The editor and sound mixer open in full mode, you can edit by talking or drawing, try changes in a copy, and the AI asks for your approval once, in the thread. Six preset looks (Paper is the default), a script teleprompter, Autopilot demos that re-record themselves, share pages on your own Cloudflare, and an MCP server so Claude Code or Codex can record, edit and share are all in.

## How it works

Press record (or ⇧⌘R from any app) → stop → the take opens as a task → the transcript and suggested cuts appear in Changes → keep or undo each one, or just ask → Post. Each project keeps its own house style and script sources (right-click it in the sidebar). The menu bar icon shows when a task needs you or an agent is working.

## v0.1 plan

- [x] Menu bar recorder, ⌘⇧R from anywhere
- [x] Screen, system sound and mic on separate tracks (ScreenCaptureKit + AVAssetWriter), crash-safe, Vision One's own windows hidden
- [x] Cursor and click log for zooms
- [x] Record picker: Screen, Window or Area, with Mic and System sound switches ([visual](https://claude.ai/artifact/HStjcoNPxsMVh3FVaXq4Sd))
- [x] Camera bubble framed by your Version One ring
- [x] Word-timed transcript on device (Parakeet via FluidAudio)
- [x] Delete words in the transcript to cut the video
- [x] Fillers, stutters and long pauses proposed as cuts (dashed until you accept them)
- [x] Captions burned into the video, plus .srt and .vtt files
- [x] Export MP4 presets: Original, 1080p, 720p and WhatsApp size (under 16 MB)

## Already in from v0.2

- Music that ducks under your voice, and sound effects with an Energy dial ([docs/SOUND.md](docs/SOUND.md))
- Brand kit with intro and outro cards and a corner logo ([docs/BRAND.md](docs/BRAND.md))
- Auto zoom on clicks and blur for secrets on screen ([docs/EFFECTS.md](docs/EFFECTS.md))
- The AI ladder: on device first, then your ChatGPT plan or your own key ([docs/AI.md](docs/AI.md)), used by the editor's Ask bar and the Agents window
- Clips and thumbnails for social apps ([docs/CLIPS.md](docs/CLIPS.md))
- Copy a style: drop a video you like and get a template with its pacing, captions and framing ([docs/STYLE.md](docs/STYLE.md))
- Autopilot: Vision One clicks through your app from saved steps while it records, and records the demo again when you ship a release ([docs/AUTOPILOT.md](docs/AUTOPILOT.md))

## Install

Download the DMG from the [latest release](https://github.com/VenusOne-Lee/vision-one/releases/latest), or use Homebrew:

```sh
brew install --cask venusone-lee/tap/vision-one
```

Vision One updates itself (Sparkle). Click the version next to the name in the menu to check now.

## Build it

Needs macOS 15 or later on Apple Silicon and Xcode 16 or later.

```sh
brew install xcodegen
xcodegen generate
open VisionOne.xcodeproj
```

**Keep access across builds.** macOS ties Screen Recording access to the app's signature, and the default ad hoc signature changes every build, so macOS would ask again each time. Sign with your own (free) Apple Development certificate instead:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then add your team ID
```

Run the `VisionOne` scheme. If you build from the command line, keep the build folder outside `~/Documents` or `~/Desktop` when those sync with iCloud: Finder adds file attributes there that make code signing fail with "resource fork, Finder information, or similar detritus not allowed". On first launch, a "Get set up" window asks for Screen Recording and Microphone access, notices when you turn them on, and restarts the app for you. Each take is a folder in `~/Movies/Vision One`. See [docs/RECORDER.md](docs/RECORDER.md).

Plain logic lives in the `VisionOneKit` Swift package, so you can run its tests without Xcode: `swift test`.

## Layout

| Path | What |
| --- | --- |
| `App/Sources` | The Mac app: menu bar, recorder, export, theme |
| `App/Sources/Harness` | The main window: projects and tasks sidebar, task thread, composer, swappable panels, empty states, project settings |
| `App/Sources/Autopilot` | Autopilot: demos that click through your app and re-record on each release |
| `App/Sources/MCP` | The MCP server bridge, so Claude Code or Codex can drive Vision One |
| `App/Sources/Share` | Share step, approvals for outbound posts, and share pages |
| `App/Sources/Recording` | Countdown, pause, mic meter, area shapes and the script teleprompter |
| `App/Sources/DesignSystem` | Tokens, components and the six preset looks |
| `App/Sources/Editor` | The editor window: takes, preview, timeline, transcript, sound panel |
| `App/Sources/Captions` | Caption drawing for the preview and burn-in, and .srt/.vtt files |
| `App/Sources/Brand` | Brand kit settings, intro and outro cards, corner logo |
| `App/Sources/Sound` | Music and sound effect mixing for preview and export |
| `App/Sources/Effects` | Auto zoom and secret blur |
| `Sources/VisionOneKit` | Testable logic: the Desk (projects, tasks, approvals), recording state, take folders, cursor log, transcript, cleanup, captions, sound, brand, AI, export plans |
| `docs/RECORDER.md` | How recording works, and what a take folder holds |
| `docs/TRANSCRIPT.md` | The transcript format every take gets |
| `docs/CLEANUP.md` | How fillers, stutters and long pauses are found and proposed |
| `docs/EXPORT.md` | How export combines the tracks, and the presets |
| `docs/SOUND.md` | Music that ducks under your voice, and sound effects |
| `docs/BRAND.md` | Brand kit, intro and outro cards, and what's not wired yet (templates, formats) |
| `docs/EFFECTS.md` | Auto zoom and secret blur |
| `docs/AI.md` | The AI ladder (on device, ChatGPT plan, Decisions API, your own key), the approval gate, and the Producer, Editor, Clipper and Sharer agents |
| `docs/CLIPS.md` | Short clips and thumbnails: finding, framing, rendering |
| `docs/STYLE.md` | Copy a style: what a video scan reads and the template it saves |
| `docs/AUTOPILOT.md` | Autopilot and self-updating demos: the demo file, plain-words steps, safety, releases and the GitHub Action |
| `docs/IPHONE.md` | Recording a plugged-in iPhone's screen, and the iPhone as a camera |
| `docs/PRESETS.md` | Prompt presets: the file format and how a prompt is put together |
| `docs/MCP.md` | The MCP server: tools, approvals, and setup in Claude Code and Codex |
| `docs/SHARE-PAGE.md` | Share pages on your own Cloudflare: notes, reactions, insights |
| `docs/AUTOPILOT.md` | Autopilot and self-updating demos |
| `docs/RELEASING.md` | Signing, notarised DMG, Sparkle updates, Homebrew, and the one-time setup |
| `scripts/release` | The release scripts the workflow runs |
| `docs/DESIGN.md` | Design system: tokens, type, components, do's and don'ts |
| `project.yml` | XcodeGen project (the `.xcodeproj` isn't committed) |

## Design rules

Light only. Ink on paper. Orange (#FF5A1F) means recording is live and nothing else. Dashed means proposed, solid means done. See [docs/DESIGN.md](docs/DESIGN.md).

## Licence

MIT. See [LICENSE](LICENSE).

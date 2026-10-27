# Vision One

A free, open source Mac screen recorder that edits itself. Record, pick what it's for, export. The AI runs on your Mac, so it costs nothing to run and your audio never leaves the device.

Made for South African builders, as the sibling of [Version One](https://versionone.co.za).

> **Status: v0.1 nearly done.** Vision One records your screen, a window or an area from the menu bar, transcribes the take on your Mac, and opens it in a transcript editor: delete words to cut the video, review the suggested filler and pause cuts, then export with captions. The camera bubble is the last v0.1 piece. Some v0.2 pieces are already in: music and sound effects, a brand kit with intro and outro cards, auto zoom and secret blur, and the AI ladder library.

## How it works

Record → stop → the editor opens on the take → the transcript and suggested cuts appear → review → Export.

Vision One has a main window (the Library of takes, and the editor) with a Dock icon, plus the menu bar panel for quick recording.

## v0.1 plan

- [x] Menu bar recorder, ⌘⇧R from anywhere
- [x] Screen, system sound and mic on separate tracks (ScreenCaptureKit + AVAssetWriter), crash-safe, Vision One's own windows hidden
- [x] Cursor and click log for zooms
- [x] Record picker: Screen, Window or Area, with Mic and System sound switches ([visual](https://claude.ai/artifact/HStjcoNPxsMVh3FVaXq4Sd))
- [ ] Camera bubble framed by your Version One ring
- [x] Word-timed transcript on device (Parakeet via FluidAudio)
- [x] Delete words in the transcript to cut the video
- [x] Fillers, stutters and long pauses proposed as cuts (dashed until you accept them)
- [x] Captions burned into the video, plus .srt and .vtt files
- [x] Export MP4 presets: Original, 1080p, 720p and WhatsApp size (under 16 MB)

## Already in from v0.2

- Music that ducks under your voice, and sound effects with an Energy dial ([docs/SOUND.md](docs/SOUND.md))
- Brand kit with intro and outro cards and a corner logo ([docs/BRAND.md](docs/BRAND.md))
- Auto zoom on clicks and blur for secrets on screen ([docs/EFFECTS.md](docs/EFFECTS.md))
- The AI ladder library: on device first, then your ChatGPT plan or your own key ([docs/AI.md](docs/AI.md)); not in the app's screens yet

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
| `App/Sources/Editor` | The editor window: takes, preview, timeline, transcript, sound panel |
| `App/Sources/Captions` | Caption drawing for the preview and burn-in, and .srt/.vtt files |
| `App/Sources/Brand` | Brand kit settings, intro and outro cards, corner logo |
| `App/Sources/Sound` | Music and sound effect mixing for preview and export |
| `App/Sources/Effects` | Auto zoom and secret blur |
| `Sources/VisionOneKit` | Testable logic: recording state, take folders, cursor log, transcript, cleanup, captions, sound, brand, AI, export plans |
| `docs/RECORDER.md` | How recording works, and what a take folder holds |
| `docs/TRANSCRIPT.md` | The transcript format every take gets |
| `docs/CLEANUP.md` | How fillers, stutters and long pauses are found and proposed |
| `docs/EXPORT.md` | How export combines the tracks, and the presets |
| `docs/SOUND.md` | Music that ducks under your voice, and sound effects |
| `docs/BRAND.md` | Brand kit, intro and outro cards, and what's not wired yet (templates, formats) |
| `docs/EFFECTS.md` | Auto zoom and secret blur |
| `docs/AI.md` | The AI ladder (on device, ChatGPT plan, Decisions API, your own key), the approval gate, and the Producer, Editor, Clipper and Sharer agents |
| `docs/CLIPS.md` | Short clips and thumbnails: finding, framing, rendering |
| `docs/IPHONE.md` | Recording a plugged-in iPhone's screen, and the iPhone as a camera |
| `docs/PRESETS.md` | Prompt presets: the file format and how a prompt is put together |
| `docs/RELEASING.md` | Signing, notarised DMG, Sparkle updates, Homebrew, and the one-time setup |
| `scripts/release` | The release scripts the workflow runs |
| `docs/DESIGN.md` | Design system: tokens, type, components, do's and don'ts |
| `project.yml` | XcodeGen project (the `.xcodeproj` isn't committed) |

## Design rules

Light only. Ink on paper. Orange (#FF5A1F) means recording is live and nothing else. Dashed means proposed, solid means done. See [docs/DESIGN.md](docs/DESIGN.md).

## Licence

MIT. See [LICENSE](LICENSE).

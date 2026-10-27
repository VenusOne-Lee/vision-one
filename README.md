# Vision One

A free, open source Mac screen recorder that edits itself. Record, pick what it's for, export. The AI runs on your Mac, so it costs nothing to run and your audio never leaves the device.

Made for South African builders, as the sibling of [Version One](https://versionone.co.za).

> **Status: v0.1 in progress.** Right now Vision One records your whole screen, one window or an area you drag, from the menu bar. Screen, system sound and mic each go on their own track, and your cursor and clicks are logged for later zooms. The transcript editor comes next.

## v0.1 plan

- [x] Menu bar recorder, ⌘⇧R from anywhere
- [x] Screen, system sound and mic on separate tracks (ScreenCaptureKit + AVAssetWriter), crash-safe, Vision One's own windows hidden
- [x] Cursor and click log for zooms
- [x] Record picker: Screen, Window or Area, with Mic and System sound switches ([visual](https://claude.ai/artifact/HStjcoNPxsMVh3FVaXq4Sd))
- [ ] Camera bubble framed by your Version One ring
- [ ] Word-timed transcript on device (WhisperKit / Parakeet)
- [ ] Delete words to cut video
- [ ] Remove fillers and long pauses
- [ ] Captions
- [x] Export MP4: Original, 1080p, 720p and WhatsApp size (under 16 MB)

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
| `App/Sources` | The Mac app: menu bar, recorder, theme |
| `Sources/VisionOneKit` | Testable logic: recording state, take folders, cursor log, timecodes, export plans |
| `docs/RECORDER.md` | How recording works, and what a take folder holds |
| `docs/EXPORT.md` | How export combines the tracks, and the presets |
| `docs/SOUND.md` | Music that ducks under your voice, and sound effects |
| `docs/RELEASING.md` | Signing, notarised DMG, Sparkle updates, Homebrew, and the one-time setup |
| `scripts/release` | The release scripts the workflow runs |
| `docs/DESIGN.md` | Design system: tokens, type, components, do's and don'ts |
| `project.yml` | XcodeGen project (the `.xcodeproj` isn't committed) |

## Design rules

Light only. Ink on paper. Orange (#FF5A1F) means recording is live and nothing else. Dashed means proposed, solid means done. See [docs/DESIGN.md](docs/DESIGN.md).

## Licence

MIT. See [LICENSE](LICENSE).

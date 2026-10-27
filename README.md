# Vision One

A free, open source Mac screen recorder that edits itself. Record, pick what it's for, export. The AI runs on your Mac, so it costs nothing to run and your audio never leaves the device.

Made for South African builders, as the sibling of [Version One](https://versionone.co.za).

> **Status: v0.1 in progress.** Right now Vision One records your whole screen, system sound and mic to an MP4 from the menu bar. The transcript editor comes next.

## v0.1 plan

- [x] Menu bar recorder, ⌘⇧R from anywhere
- [x] Screen + system sound + mic to MP4 (ScreenCaptureKit), Vision One's own windows hidden
- [ ] Camera bubble framed by your Version One ring
- [ ] Word-timed transcript on device (WhisperKit / Parakeet)
- [ ] Delete words to cut video
- [ ] Remove fillers and long pauses
- [ ] Captions
- [ ] Export MP4 (and WhatsApp size, under 16 MB)

## Build it

Needs macOS 15 or later on Apple Silicon and Xcode 16 or later.

```sh
brew install xcodegen
xcodegen generate
open VisionOne.xcodeproj
```

Run the `VisionOne` scheme. The first time you record, macOS asks for Screen Recording and Microphone access. Recordings go to `~/Movies/Vision One`.

Plain logic lives in the `VisionOneKit` Swift package, so you can run its tests without Xcode: `swift test`.

## Layout

| Path | What |
| --- | --- |
| `App/Sources` | The Mac app: menu bar, recorder, theme |
| `Sources/VisionOneKit` | Testable logic: recording state, file names, timecodes |
| `docs/DESIGN.md` | Design system: tokens, type, components, do's and don'ts |
| `project.yml` | XcodeGen project (the `.xcodeproj` isn't committed) |

## Design rules

Light only. Ink on paper. Orange (#FF5A1F) means recording is live and nothing else. Dashed means proposed, solid means done. See [docs/DESIGN.md](docs/DESIGN.md).

## Licence

MIT. See [LICENSE](LICENSE).

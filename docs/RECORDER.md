# How the recorder works

Vision One records each source on its own track and combines them only at export. That's how editors like Cap work, and it lets the transcript, zooms and camera bubble each work on their own piece. The research behind this choice: [Vision One: how to build the recorder](https://claude.ai/artifact/UTdz8wjdX48mpuExVoWTGB).

## A take

Each recording is one folder in `~/Movies/Vision One`:

| File | What |
| --- | --- |
| `screen.mov` | Video (HEVC), then a system sound track and a mic track (AAC), each left out when switched off |
| `events.json` | Cursor moves and clicks, in seconds from the first frame. Positions are in points from the top left of what was recorded (display, window or area) |
| `camera.mov` | The camera (H.264, never mirrored), when Camera is on in Sources |
| `camera.json` | `startOffset`: seconds from screen.mov's first frame to camera.mov's. `placements`: where the bubble sat, as shares of what was recorded (top left origin), each with its time |
| `phone.mov` | A plugged-in iPhone's screen and sound, when you picked one (see [IPHONE.md](IPHONE.md)) |

## What to record

The menu bar panel picks Screen, Window or Area, plus Mic and System sound. The choice is saved, so ⌘⇧R records the same way next time. See the [visual](https://claude.ai/artifact/HStjcoNPxsMVh3FVaXq4Sd) (source in `docs/visuals/record-picker.html`).

- **Screen:** the chosen display, minus Vision One's own windows.
- **Window:** `SCContentFilter(desktopIndependentWindow:)`, which follows the window when it's moved or covered.
- **Area:** the display filter with `sourceRect` set to the chosen rectangle. You draw it, then move it or resize it from eight handles; it stays on screen and at least 64 points a side. Sides are rounded down to even pixels for HEVC. A thin orange frame marks the area while live; it isn't recorded.

## The camera bubble

Switch on Camera in Sources and a round live preview in your ring colour (from Brand) floats over everything. See the [visual](https://claude.ai/artifact/GqVoHVpgnxe2oZwed2GMY5) (source in `docs/visuals/camera-bubble.html`). It's mirrored, like a mirror; camera.mov isn't.

- **Move:** drag it anywhere, across displays too. It stays whole and 16 points from the screen's edges.
- **Resize:** hover to show the handle at the bottom right, then drag it. 96 points up to half the screen's shorter side. Right-click for Small, Medium or Large.
- **Remembered:** where you left it, as a share of the screen, so it keeps its corner when the resolution changes.
- **While recording:** a small orange dot shows it's live. It never lands in screen.mov, because Vision One's windows are left out of the capture. Moves are logged in camera.json, and export draws the camera where you saw it (see [EXPORT.md](EXPORT.md)).
- **Which camera:** Automatic follows macOS, so an iPhone on a stand (Continuity Camera) takes over by itself. Or pick one from the row's menu. The choice lives in `CaptureDevices`.

One `AVCaptureSession` feeds both the preview and `AVAssetWriter`, so camera.mov's first frame is known on the host clock that screen.mov uses (`CameraBubble.swift`). The camera starts just before the screen, so `startOffset` is usually a little negative.

## Pipeline

1. `SCStream` delivers screen frames, system sound and mic buffers on one capture queue.
2. `TakeWriter` writes them with `AVAssetWriter`. Idle frames are skipped. The session starts at the first complete frame, and audio from before it is dropped so every track starts together.
3. `movieFragmentInterval` is 2 seconds, so a crash leaves a playable file missing only the last few seconds.
4. `CursorLogger` timestamps global mouse events on the same host clock and writes `events.json` when you stop.

## While recording

Mockups and research: https://claude.ai/artifact/XXu8UWfzJvLGZFc1FbebLZ

- **Countdown.** Every record button and ⌘⇧R count down first (3 s by default; Off or 5 s under Home's record button). Click or Space starts at once, Esc or Cancel stops. Ink, not orange, because nothing records yet. The main window steps aside and the app you were in comes back to the front.
- **Pause** (bar button or ⌥⇧P). Screen frames and camera frames are dropped and sound is written as silence, so nothing from the pause is kept. No clock is rewritten: `PauseLog` keeps the paused stretches on the host clock and, at stop, they go into `edits.json` as accepted cuts with reason `paused`. The editor and export skip them like any cut, and camera.json, events.json and phone.mov stay lined up untouched.
- **Restart and delete** ask inline in the bar (recording pauses while it asks). The take folder goes to the Bin. Restart counts down again with the same choices; delete brings the main window back and doesn't open the editor.
- **Mic meter.** `CaptureSink` reads the peak of about fifteen mic buffers a second into `MicLevelMeter` (fast attack, 24 dB/s release). Nothing above −50 dBFS for 6 s shows "Can't hear you · check the mic".
- **Area shapes.** Free, 16:9, 9:16 or 1:1. Picking one snaps the area to the biggest box of that shape inside it, and drawing and resizing keep it. Arrow keys nudge by a point, Shift-arrow by ten.

## Not yet

- Showing and moving the bubble in the editor's preview
- The bubble in short clips
- Following a window's moves in the cursor log (v1 uses its frame at start)
- Lower frame rate and resolution on 8 GB Macs
- Hiding the real cursor and drawing a smooth one (v0.2, needs export)

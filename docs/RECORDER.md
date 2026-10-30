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

## Camera only

The fourth choice next to Screen, Window and Area, and a pill beside Home's record button. It records just you and your mic, with nothing from the screen. See the [visual](https://claude.ai/artifact/JrGtfiEMAkW22fxkk91uJ5) (source in `docs/visuals/camera-only.html`).

- **No Screen Recording needed.** It never touches ScreenCaptureKit, only Camera and Microphone, asked for the first time you record this way.
- **The camera is the main video.** `CameraOnlyCapture` runs one `AVCaptureSession` with the camera and mic and writes `screen.mov` itself: H.264 at 1080p when the camera has it (else 720p), plus a mono AAC mic track and `audio-tracks.json`. So the transcript, editor, captions, clips and export treat it like any take. There's no `events.json`, `camera.mov` or system sound.
- **Which camera:** the one picked in Sources, or Automatic when the bubble is off.
- **The stage.** A big 16:9 preview in your ring colour, mirrored like a mirror (the file isn't). It opens when you press record, so you can frame yourself during the countdown. Drag it, resize it from any edge, and it opens where you left it. The orange dot shows it's live. The bubble hides while the stage is up.
- Countdown, pause, restart, delete, the mic meter and the teleprompter work as they do for the screen.

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

## Recording from a script

Add a script from the Script row on Home (or the coach, or an agent, through UserDefaults `script.text`). Each sentence becomes a line.

- **Teleprompter.** It shows during the countdown, top centre under the menu bar so your eyes stay near the camera. Like every Vision One window it's left out of the capture. Drag it, resize it from its edges, and it opens where you left it. Said words fade and the next word is underlined. Its menu picks Follow my voice or Scroll steadily (120, 150 or 180 words a minute; a steady scroll waits while paused), and the text size.
- **Follows your voice, on this Mac.** `ScriptVoice` feeds the mic buffers already being recorded to `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, and `ScriptFollower` moves along the script: it skips a missed word or two, ignores fillers, and jumps back when you start a line again. Without speech permission it scrolls instead.
- **Best try per line.** The script is saved with the take as `script.json`. After transcription, `ScriptRetakes` finds each try at each line (`script-takes.json`) and keeps the most complete, then the cleanest, then the latest. The other tries become proposed cuts with reason `repeat`, so you accept or reject them in the editor like any other suggestion. `[audio tags]` in the script aren't read or counted.

## Not yet

- Moving the camera bubble directly in the editor's preview (the recorded placement is now rendered there)
- Following a window's moves in the cursor log (v1 uses its frame at start)
- Lower frame rate and resolution on 8 GB Macs
- Hiding the real cursor and drawing a smooth one (v0.2, needs export)

## Producer Workspace preparation

New task and the composer open one preparation sheet with the existing `CapturePicker` and `SourcesList`, a source snapshot, a selected-microphone level test, explicit access controls, countdown and script access. The sheet height follows the active screen's visible height and scrolls its controls. It does not request access simply to take a snapshot or test a microphone; use the labelled Allow buttons first. Existing camera-on behaviour retains its separate floating preview.

The microphone probe runs off the main thread and never writes audio to disk. Start/cancel/source-change/dismiss revoke a generation before awaiting session shutdown, so an old start or queued meter callback cannot restore a stopped probe. CI also exercises this race with a delayed fake probe. Real input-device and permission-transition checks remain open.

Recording setup remembers source/countdown choices per project. Stop attaches the recording to the captured task/project before transcription and default application. Global hotkeys, pause/resume, restart/delete and agent recording remain available.

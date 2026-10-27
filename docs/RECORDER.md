# How the recorder works

Vision One records each source on its own track and combines them only at export. That's how editors like Cap work, and it lets the transcript, zooms and camera bubble each work on their own piece. The research behind this choice: [Vision One: how to build the recorder](https://claude.ai/artifact/UTdz8wjdX48mpuExVoWTGB).

## A take

Each recording is one folder in `~/Movies/Vision One`:

| File | What |
| --- | --- |
| `screen.mov` | Video (HEVC), then a system sound track and a mic track (AAC), each left out when switched off |
| `events.json` | Cursor moves and clicks, in seconds from the first frame. Positions are in points from the top left of what was recorded (display, window or area) |
| `camera.mov` | Coming next: the camera, drawn in the ring bubble at export |

## What to record

The menu bar panel picks Screen, Window or Area, plus Mic and System sound. The choice is saved, so ⌘⇧R records the same way next time. See the [visual](https://claude.ai/artifact/HStjcoNPxsMVh3FVaXq4Sd) (source in `docs/visuals/record-picker.html`).

- **Screen:** the chosen display, minus Vision One's own windows.
- **Window:** `SCContentFilter(desktopIndependentWindow:)`, which follows the window when it's moved or covered.
- **Area:** the display filter with `sourceRect` set to the chosen rectangle. You draw it, then move it or resize it from eight handles; it stays on screen and at least 64 points a side. Sides are rounded down to even pixels for HEVC. A thin orange frame marks the area while live; it isn't recorded.

## Pipeline

1. `SCStream` delivers screen frames, system sound and mic buffers on one capture queue.
2. `TakeWriter` writes them with `AVAssetWriter`. Idle frames are skipped. The session starts at the first complete frame, and audio from before it is dropped so every track starts together.
3. `movieFragmentInterval` is 2 seconds, so a crash leaves a playable file missing only the last few seconds.
4. `CursorLogger` timestamps global mouse events on the same host clock and writes `events.json` when you stop.

## Not yet

- Camera recording, and the ring bubble at export
- Picking a mic, and a level meter
- Following a window's moves in the cursor log (v1 uses its frame at start)
- Lower frame rate and resolution on 8 GB Macs
- Hiding the real cursor and drawing a smooth one (v0.2, needs export)

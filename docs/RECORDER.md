# How the recorder works

Vision One records each source on its own track and combines them only at export. That's how editors like Cap work, and it lets the transcript, zooms and camera bubble each work on their own piece. The research behind this choice: [Vision One: how to build the recorder](https://claude.ai/artifact/UTdz8wjdX48mpuExVoWTGB).

## A take

Each recording is one folder in `~/Movies/Vision One`:

| File | What |
| --- | --- |
| `screen.mov` | Screen video (HEVC), a system sound track and a mic track (AAC), in that order |
| `events.json` | Cursor moves and clicks, in seconds from the first frame, positions in display points (origin top left) |
| `camera.mov` | Coming next: the camera, drawn in the ring bubble at export |
| `phone.mov` | A plugged-in iPhone's screen and sound, when you picked one (see [IPHONE.md](IPHONE.md)) |

## Pipeline

1. `SCStream` delivers screen frames, system sound and mic buffers on one capture queue.
2. `TakeWriter` writes them with `AVAssetWriter`. Idle frames are skipped. The session starts at the first complete frame, and audio from before it is dropped so every track starts together.
3. `movieFragmentInterval` is 2 seconds, so a crash leaves a playable file missing only the last few seconds.
4. `CursorLogger` timestamps global mouse events on the same host clock and writes `events.json` when you stop.

## Not yet

- Camera recording, and the ring bubble at export
- Picking a mic, and a level meter
- Lower frame rate and resolution on 8 GB Macs
- Hiding the real cursor and drawing a smooth one (v0.2, needs export)

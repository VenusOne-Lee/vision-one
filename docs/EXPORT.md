# How export works

Export turns a take and its edits into one MP4 that plays everywhere (H.264 video, AAC sound). The tracks stay separate while you edit and are combined only here. Visual overview and research: see the export artifact linked from the PR.

## Pipeline

1. **Plan.** `ExportTimeline` (VisionOneKit) takes the kept spans from the take's `edits.json` (accepted cuts only), snaps their edges to whole frames and lays them end to end. `ExportPlanner` picks size, frame rate and bitrates for the preset.
2. **Splice.** `VideoExporter` inserts each kept span of the screen, system sound and mic tracks into one `AVMutableComposition`. An `AVAudioMix` fades the sound out and in over 12 ms at every cut so cuts don't click. Music and sound effects from `sound.json` go on extra tracks with their own volume ramps (see [SOUND.md](SOUND.md)).
3. **Draw.** `FrameCompositor`, a custom `AVVideoCompositing`, blurs secrets and applies the zoom (`FrameEffects`, see [EFFECTS.md](EFFECTS.md)), scales each frame on the GPU with Core Image, then lets each `ExportOverlay` draw on top: burned-in captions and the corner logo now, the camera bubble later. Brand intro and outro cards get their own instructions before and after the video (see [BRAND.md](BRAND.md)).

4. **Encode.** `AVAssetReader` pulls the mixed frames and sound and `AVAssetWriter` encodes them at the planned bitrate. The file is written as a hidden `.partial.mp4` and renamed when done, so a failed export never leaves half a file.

We don't use `AVAssetExportSession`: it can't set a bitrate, so it can't promise a size. We don't bundle FFmpeg: the Mac's own hardware H.264 encoder is faster and there's no licence to manage.

## Presets

| Preset | Size | Frame rate | Video bitrate |
| --- | --- | --- | --- |
| Original | as recorded, long edge up to 3840 | up to 60 | 0.1 bits per pixel (0.07 above 30 fps), max 40 Mbps |
| 1080p | short edge 1080 | up to 60 | same rule |
| 720p | short edge 720 | up to 30 | same rule |
| WhatsApp | 720p, stepping down to 540p, 480p, 360p | 30, then 24 | whatever fits 90% of 16 MB |

WhatsApp works out the bitrate from the edited length. It uses the largest size that still gets enough bits per pixel to keep text readable, and short videos don't use the whole budget. If the encoder overshoots, it exports once more at a lower bitrate. Past about 7 minutes (depends on screen shape) it says how many parts to send instead.

## Files

Exports sit in the take folder, named after the take: `Vision One 2026-10-27 at 10.53.12 (WhatsApp).mp4`.

## Not yet

- Camera bubble overlay (needs `camera.mov`)
- Vertical and square clips: see [CLIPS.md](CLIPS.md). `VideoFormat` and `ReframePlanner` are in (see [BRAND.md](BRAND.md)); full-length vertical exports and a window that moves with the cursor come next
- Captions file next to the video (captions thread)

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

WhatsApp works out the bitrate from the edited length. It uses the largest size that still gets enough bits per pixel to keep text readable, and short videos don't use the whole budget. The hardware encoder only roughly meets its average bitrate, so if the file comes out over 16 MB it exports again at a lower bitrate worked out from what it actually wrote (`ExportPlanner.retryVideoBitRate`: only the video's share shrinks, aiming at 85% of the limit, then 80%). That's up to 3 tries in all; the progress ring gives the first try 70% and the retries share the rest, so it never runs backwards. If the third try is still too big, the file is deleted and export says "Still over 16 MB. Cut it shorter or pick 720p." Past about 7 minutes (depends on screen shape) it says how many parts to send instead.

## Files

Exports sit in the take folder, named after the take: `Vision One 2026-10-27 at 10.53.12 (WhatsApp).mp4`.

The recording's own length always sets where the video ends. `edits.json` can store a slightly shorter length (auto clean saves the mic's), and export keeps the tail past it rather than trimming the end.

### Captions

Burned-in captions are built inside `VideoExporter` from the same frame-snapped `ExportTimeline` it renders, so words stay on the frames where they're said however many cuts there are. They run on the edited video's clock; the compositor takes the brand intro off.

With **Also save .srt and .vtt** on in the caption controls, subtitle files go next to the video with the same name (`… (WhatsApp).srt` and `.vtt`, the VTT with word timings). They're written only after the video has finished, from the timeline the export used, and moved later by the brand intro's length so they line up with the file. A cancelled or failed export writes none, and one that leaves no video behind also removes subtitle files an earlier export left under that name.

## Not yet

- Camera bubble overlay (needs `camera.mov`)
- Vertical and square exports: `VideoFormat` and `ReframePlanner` are in (see [BRAND.md](BRAND.md)); the compositor crop comes with clips
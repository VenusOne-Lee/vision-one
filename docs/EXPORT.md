# How export works

Export turns a take and its edits into one MP4 that plays everywhere (H.264 video, AAC sound). The tracks stay separate while you edit and are combined only here. Visual overview and research: see the export artifact linked from the PR.

## Pipeline

1. **Plan.** `ExportTimeline` (VisionOneKit) takes the kept spans from the take's `edits.json` (accepted cuts only), snaps their edges to whole frames and lays them end to end. `ExportPlanner` picks size, frame rate and bitrates for the preset.
2. **Splice.** `VideoExporter` inserts each kept span of the screen, system sound and mic tracks into one `AVMutableComposition`. An `AVAudioMix` fades the sound out and in over 12 ms at every cut so cuts don't click. Music and sound effects from `sound.json` go on extra tracks with their own volume ramps (see [SOUND.md](SOUND.md)).
3. **Draw.** `FrameCompositor`, a custom `AVVideoCompositing`, blurs secrets and applies the zoom (`FrameEffects`, see [EFFECTS.md](EFFECTS.md)), scales each frame on the GPU with Core Image, draws the camera bubble, then lets each `ExportOverlay` draw on top: burned-in captions and the corner logo. The bubble is `camera.mov` on its own composition track, cut like the screen and shifted by camera.json's `startOffset`; the compositor takes the middle square of each camera frame, cuts it to a circle at the spot camera.json logged (following the cuts), and strokes the builder's ring around it. Takes without a camera export as before; clips leave the bubble out for now. Brand intro and outro cards get their own instructions before and after the video (see [BRAND.md](BRAND.md)).

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

## Export sheet

The editor's Export button opens a sheet: each preset is a tile drawn to the recording's real shape (solid when picked, dashed when not), with its length and rough size, next to the caption style chips and the Captions and Burn in switches. Export runs the picked presets one after another. The menu bar panel keeps its quick Export menu.

## Files

Exports sit in the take folder, named after the take: `Vision One 2026-10-27 at 10.53.12 (WhatsApp).mp4`.

The recording's own length always sets where the video ends. Export and the editor both use screen.mov's length, even if an older `edits.json` stored a shorter one (the mic's), so the end of the video is never trimmed.

### Captions

Burned-in captions are built inside `VideoExporter` from the same frame-snapped `ExportTimeline` it renders, so words stay on the frames where they're said however many cuts there are. They run on the edited video's clock; the compositor takes the brand intro off.

With **Also save .srt and .vtt** on in the caption controls, subtitle files go next to the video with the same name (`… (WhatsApp).srt` and `.vtt`, the VTT with word timings). They're written only after the video has finished, from the timeline the export used, and moved later by the brand intro's length so they line up with the file. A cancelled or failed export writes none, and one that leaves no video behind also removes subtitle files an earlier export left under that name.

### Sharing

The export sheet runs its batch in the app's one `ExportQueue`, so closing the sheet doesn't stop it, and opening Export again for that take shows where it's got to. The footer guesses the time left (`ExportProgress`, each format weighted by its pixels). Takes with no purpose start with whatever was exported last.

Once the batch is done, the sheet becomes the share step (`FinishedPanel`):

- **Drag** any file row into WhatsApp, Slack, Mail or Finder. **Copy** puts the file itself on the clipboard, so ⌘V pastes the video. **Show** reveals it. **More** is the Mac's share menu (AirDrop, Messages, Mail).
- **WhatsApp, LinkedIn, X, YouTube** (`ShareTarget`, VisionOneKit) each pick the file that suits them (WhatsApp the ≤16 MB one, LinkedIn Square, X and YouTube 1080p, falling back to whatever was exported) and the Sharer's words for that network from share.json. YouTube gets the title, description and chapters.
- Tapping one opens a dashed post card with those words, editable, and "Draft with Sharer" when there's no draft yet. **Approve and open** turns it solid, records the approval with `OutboundGate.approvedInPlace` (the card showed the exact words and destination, so it isn't asked twice), copies the words, shows the file in Finder and opens the network's composer. Nothing posts until you press Post there. Posting straight through each network's API comes with the MCP server.

### Ready to share and the Post panel

Stop opens **Ready to share** (`App/Sources/Share/ReadyToShareView.swift`), after Loom: the take, a checklist (saved, transcript, Sharer draft, export), **Copy video** (⇧⌘C) and **Edit** (⇧⌘E). Copy video exports the take's first suggested format if it isn't there yet, then puts the file on the clipboard. "After Stop, open" at the bottom switches Stop back to the editor.

Beside it is the **Post panel** (`PostPanel(take:)`), the same view the task window's Post tab embeds: the Version One draft (Approve and post, Edit), then WhatsApp, LinkedIn, X and YouTube with the Sharer's words and the file each one takes (or Export first). Approving goes through a Codex-style card (`ApprovalCard`): 1 Yes, post it · 2 Yes, and don't ask again for *product* posts · 3 No, and tell the Sharer what to do differently. ↑↓, Return, 1 to 3, Esc to decide later. Option 3 writes the draft again with your note.

"Don't ask again" is a rule per product (the brand kit's name) and place, saved in `~/Library/Application Support/Vision One/post-rules.json` (`PostRules`). It only skips the card: the words are still copied and the place to post still opens, where you press post yourself. Each rule shows **Ask every time** to undo it. The link row appears once the share page is published (`ShareLinks.lookup`). Every colour comes from `Theme`, so preset looks apply.

## Not yet

- The camera bubble in short clips, and moving or hiding it in the editor
- A share link (Loom style). It needs storage the builder brings, such as their own Drive or S3
- A notification when a background export finishes while the sheet is closed

## Producer Workspace delivery updates

`ExportQueue` serialises batches across multiple takes and retains per-take results while another task runs. Each take has queued/running/failed/cancelled states and retry of unfinished outputs. Cancel in one take's export sheet cancels that take, including a queued request. Queued work reads the take's saved settings when it starts; the UI says so. The queue currently lives in the app process and is not restored after quitting.

Portrait 4:5 is an explicit output preset, including template defaults. Split template framing places the screen above a camera pane when a separate camera is present. Imported rotation metadata is applied before effects and reframing. Camera overlays compose after crop. Subtitle-write errors are visible warnings attached to the completed video; disabling subtitle files removes stale sidecars.

CI can run the built binary with `--verify-media <temporary-output-folder>` to render a deterministic fixture and retain MP4/PNG/SRT/VTT/JSON evidence. This diagnostic uses no recording permissions or external provider. Its actual result is tracked per commit in `CLOUD-VERIFICATION.md`.

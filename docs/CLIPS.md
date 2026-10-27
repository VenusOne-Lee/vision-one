# Clips and thumbnails

Short clips for Shorts, Reels, TikTok and LinkedIn, and thumbnails for YouTube and covers, made from a take you already edited. Visual overview, mockups and research: https://claude.ai/artifact/EeCHQEmAKZWN3AT6zyTTZY

## Clips

**Finding.** `ClipFinder` (VisionOneKit) runs on the Mac with no AI service. It splits the transcript into sentences (full stops, question marks and pauses of 0.8 s or more), leaves out words the editor cut, tries every run of whole sentences that lasts 15 to 60 s once cuts are left out, and scores each one:

| Part | Weight | What scores well |
| --- | --- | --- |
| Hook | 0.30 | Opens with a question, a strong opener ("Here's", "How", "Why", "The trick") or a number; not "and", "but", "so" |
| Complete | 0.25 | Ends on a full stop and doesn't start mid-thought |
| Pace | 0.15 | 2.3 to 3.6 words a second |
| Clean | 0.15 | Few um and uh left in |
| Length | 0.15 | Close to 35 s |

The best five that don't overlap are added as dashed suggestions. The Clipper agent can take the same candidates and rescore and title them through the AI ladder; it writes the same `Clip` shape.

**clips.json.** One file per take, next to edits.json. A clip is a span of the take (same clock as edits.json), so cuts inside it are left out of the clip too. Suggestions that mostly overlap a clip already in the file are skipped, so turned-down clips don't come back.

```json
{ "version": 1, "clips": [{
  "id": "…", "title": "Ship your first beta in 10 minutes", "hook": "Here's the fastest way…",
  "start": 68.4, "end": 101.0, "score": 0.82, "reason": "strong opening",
  "origin": "auto", "state": "proposed", "format": "vertical",
  "framing": { "mode": "follow", "centerX": 0.5, "centerY": 0.5 } }] }
```

**Formats.** Vertical 1080 × 1920, square 1080 × 1080, wide 1920 × 1080, at up to 30 fps.

**Framing.** `ClipFrame.rect` is the largest window of the format's shape that fits the screen, centred where asked and slid back inside the frame. `follow` centres on where the cursor spent the clip (median position, clicks count three times); `fixed` stays where you dragged it on the video; `fit` shows the whole screen on the canvas colour. A moving follow-the-cursor window comes from the shared reframe planner (brand kit work).

**Export.** `VideoExporter` with the clip's kept spans and a crop. `FrameCompositor` cuts the window out of each frame (after blur and zoom) and scales it to the format. Files sit in the take folder: `Vision One 2026-10-27 at 10.53.12 - Ship your first beta (vertical).mp4`.

## Thumbnails

**Picking frames.** `ThumbnailPicker` spreads 16 sample times across the edited video, skipping the first and last 5% and staying 0.5 s away from cuts. The app grabs each frame and measures it: edge energy for sharpness (relative to the take's sharpest frame), mean brightness, Vision's face capture quality on the camera (or the screen when there's no camera), cursor speed from events.json and the distance from a cut. It offers the best five at least 3 s apart.

**Design.** `thumbnails/thumbnail.json` keeps the frame, title, where the title and camera bubble sit, their sizes and the chosen image sizes, so the tab opens the way you left it. The title is suggested from the best clip, otherwise the first sentence, cut to six words.

**Drawing.** Core Graphics: the frame fills the image, a shade rises from the bottom so white type reads, the title is set as large as fits its box in up to three lines, and the camera sits in the builder's ring. The editor preview is drawn by the same code at half size.

| Size | Pixels | File |
| --- | --- | --- |
| YouTube | 1280 × 720 | thumbnail-youtube.jpg, under 2 MB |
| Cover | 1080 × 1920 | thumbnail-cover.png |
| Square | 1080 × 1080 | thumbnail-square.png |

## Not yet

- Burned-in captions on clips (once captions land, pass the caption overlay)
- A window that moves with the cursor during the clip (`ReframePlan`)
- Brand kit fonts and ring colour (`ThumbnailStyle(brandKit:)`)
- AI-made covers with your own OpenAI key

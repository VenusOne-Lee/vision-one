# Auto zoom and secret blur

Two edits that change the picture rather than the timeline. Both are kept next to the recording (`zooms.json`, `blurs.json`), timed on the take's own clock like `edits.json`, so they survive cuts and undo and never touch `screen.mov`. Both follow the app's grammar: dashed while proposed, solid once accepted.

## Auto zoom

`ZoomPlanner` (VisionOneKit) reads the click log in `events.json` and does what Screen Studio, Cap and Tella do for a first pass:

1. Clicks close in time (`mergeGap`) and place (inside what the zoomed camera could show) become one zoom.
2. The zoom starts `lead` seconds before the first click, so it has landed by the time the click happens, and holds `hold` seconds after the last one.
3. Neighbours that overlap hand over with a pan instead of zooming out and back in. Clicks inside cuts don't zoom.

The Energy dial sets the style: Calm (1.5x, slow, holds still), Lively (2x, follows the cursor), Viral (2.6x, quick). Changing it re-plans the proposals and leaves accepted and turned-off zooms alone.

`ZoomTrack` turns accepted zooms into a camera path: for any moment, the part of the frame on screen. It eases in and out with a cubic curve, follows the cursor averaged over half a second when the zoom follows the cursor, and always stays inside the frame. Only accepted zooms move the camera.

## Secret blur

`SecretFinder` (app) reads the text on screen with Vision (`VNRecognizeTextRequest`, accurate, language correction off) twice a second, skipping frames where nothing changed. `SecretScanner` (VisionOneKit) flags API keys and tokens by their known prefixes (OpenAI, Anthropic, GitHub, AWS, Google, Stripe, Slack, Hugging Face, JWTs, private keys), values after `password=` / `api_key:` and passwords in connection strings, card numbers and South African ID numbers (both with their check digits), and long random strings. `BlurPlanner` joins the same secret across frames into one blur that reaches past the frames on either side, and pads the box so no edge of a letter shows. The secret itself is never written down, only its kind.

Blurs hide from the moment they're found: a proposed blur is dashed in the editor but still blurs the export. Leaking a key because nobody pressed Accept is the worse mistake. Turning a blur off lets the frame through.

**Secure blur.** A Gaussian blur or pixelation depends on what's underneath, and tools like Depix can read text back out of it. `FrameEffectRenderer.hide` fills each box only from the pixels around it (normalised convolution), so two frames with different keys in the same place come out identical. It looks like frosted glass and hides like a solid bar.

**Limits.** A key on screen for less than half a second between two scanned frames can be missed, and OCR can misread tiny or stylised text. "Blur here" adds a box by hand.

## Rendering

`FrameCompositor` does, for every frame of the export and of the editor's preview:

1. blurs, on the whole frame, so nothing escapes through a zoom or a crop
2. the zoom viewport
3. a clip's crop (clips thread), inside the viewport
4. scale to the output size
5. overlays (captions, camera bubble)

All boxes use `FrameRect`: 0...1 of the frame, origin top left. The editor previews through the same compositor, so what you see is what exports. While adjusting, the preview shows the whole frame so the boxes can be dragged and resized.

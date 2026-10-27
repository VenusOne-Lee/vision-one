# Brand kit, templates and formats

Your look on every video, in every shape. Visual overview and research: [Vision One Brand Kit](https://claude.ai/artifact/8D2qAGbqgsCD4cs7UPquBA).

## Brand kit

`BrandKit` (VisionOneKit) is saved as `brand.json` in `~/Library/Application Support/Vision One/Brand/`, with the logo file beside it. Plain files, so a brand can be shared by copying the folder. Edit it in **Brand** from the menu bar.

| Field | What it does |
| --- | --- |
| `name`, `tagline`, `site`, `cta` | Text on the cards; `{product}`, `{site}`, `{cta}` for prompts |
| `ring` | Ring colour from Version One: blue, red, gold, green, purple, pink, black. Identity, never UI state. Draws the card rings and keyword captions |
| `logo` | File name inside the brand folder (`logo.png`, `.svg`, `.jpg`, `.webp`) |
| `fonts` | Display and body fonts for the videos; Bricolage Grotesque and Source Serif 4 by default |
| `intro`, `outro` | On or off, 1 to 8 seconds. Off until you turn them on |
| `watermark` | Corner logo: on or off, where you dragged it, size, opacity |

A missing field falls back to its default, so old files keep working.

## Templates

> **Not yet.** `TemplateLook` and `template.json` are in VisionOneKit and the card renderer can take one, but nothing loads a template folder and there is no template picker. Export always uses the brand kit's own cards. Everything in this section is the plan.

A template's look is a folder that HyperFrames tooling can read too:

```
launch/
  template.json   TemplateLook: purpose, cards, formats, caption style
  intro.html      HyperFrames composition (optional)
  outro.html      HyperFrames composition (optional)
  prompts.md      part prompts (the AI side owns these)
```

`TemplateLook` holds the look only. What the video is for, its energy, length and prompts belong to `Purpose` on the AI side; a look names its purpose with `purposeID`. Built in: Launch video, Product demo, Short, Tutorial, Bug report, What's new, Talking head, Blank.

`intro` and `outro` are `"brand"` (the kit's own card, if it's on), `"none"`, or an HTML file in the folder. Card paths can't leave the template folder.

### Card format

Cards follow HyperFrames: a root element with `data-composition-id`, `data-width`, `data-height` and `data-duration`, and clips with `class="clip"`, `data-start`, `data-duration` and `data-track-index`. Animations must be seekable: CSS animations, Web Animations, a paused GSAP timeline in `window.__timelines`, or `window.__hf.seek(t)`.

Brand values arrive as CSS variables (`--ring`, `--paper`, `--ink`, `--display-font`, `--body-font`) and as text in elements with `data-var="name"` (`name`, `product`, `tagline`, `site`, `cta`, `initial`, `title`), set with `textContent`. `img[data-var="logo"]` gets the logo. `data-if="tagline"` removes an element when the value is empty; `data-unless="logo"` removes it when there is a logo.

Rules, as in HyperFrames: no `Date.now()`, no unseeded random, no free-running loops. Nothing loads from the network; the web view only reads the template folder.

## How cards render (no Chrome)

HyperFrames seeks headless Chrome to each frame and captures it. `CardRenderer` does the same with WebKit:

1. Load the card in an off-screen `WKWebView` (borderless window, hidden from screen recordings, network blocked).
2. Run `CardScript.prepare`: fill in the brand, wait for fonts and images.
3. For each frame: `CardScript.seek(t)` pauses every animation at `t`, then `takeSnapshot` captures it at the export size.
4. Frames are kept as PNG; repeats (once the animation settles) are stored once.

If anything fails (load, snapshot, a blank result), the export uses `NativeCard`, the same card drawn with Core Graphics, so an export never fails over its intro.

Export puts the cards around the edited video (`TemplatePlan`): a gap at the start of every track for the intro and one after the video for the outro, drawn by `FrameCompositor`. Captions and other overlays keep the edited video's clock.

## Formats and reframing

> **Not yet.** `VideoFormat`, `ReframePlanner` and `ReframePlan` are in VisionOneKit with tests, but export and the editor don't use them: every export keeps the recording's shape. Everything in this section is the plan.

`VideoFormat` is the shape (16:9, 9:16, 1:1, 4:5), separate from the preset, which decides size and bitrate. `ReframePlanner` turns what should stay in frame (cursor and clicks from `events.json`, faces later) into a `ReframePlan` per format:

- **Follow** crops to the format and follows the focus. Export isn't live, so it looks 0.4 s ahead, holds still inside a dead zone (12% of the crop), pans no faster than 1.5 crop widths a second, and smooths forwards and backwards so it never lags.
- **Fit** shows the whole frame on paper, with room for captions.
- **Split** puts the screen in the top 60% and the camera below.

Crops are `NormalisedRect`, 0...1 from the top left. Dragging the crop window pins it over a stretch (`ReframePlan.pin`); pins win over following.

## Still to do

- Check on a Mac: snapshot speed at 1080p, fonts inside the web view, transparency for lower thirds
- Template picker in the editor (with the AI side's purpose picker)
- Reframed export: the compositor crop hook comes with clips
- Import ring colour and logo from your Version One profile
- Cache rendered cards on disk between exports

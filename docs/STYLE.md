# Copy a style

Drop a video you like (or paste its link) and Vision One turns how it is made into a template you can record into. It copies style, never content: frames and sound are read in memory and thrown away, and only numbers are saved. Visual overview and research: [Vision One Copy a Style](https://claude.ai/artifact/61semnX7PdHwfEB6RtTL6x).

Open it from **File → Copy a Style…** or the dashed **Copy a style…** card on Home.

## What it reads

| Trait | How | Sets |
| --- | --- | --- |
| Cut rhythm | 4 frames a second, shrunk to 160 px. A 4×4×4 RGB histogram per quarter of the frame; a cut is a frame that differs from the last by 0.3 or more and by 2.5× the change around it (PySceneDetect's adaptive idea) | Pace, cuts a minute, Energy, kept pause length |
| Captions | Vision text (fast) once a second. Words between 30% and 92% down that change at least 6 times a minute and show on a quarter of frames | Caption style: 1–3 words Bold pop, up to 6 Word by word (Keyword when upper case), longer Subtitle |
| Framing | Vision face boxes once a second | Talking head (face on half the frames, 3%+ of the picture), camera bubble (small, off centre) or screen |
| Zooms | The same face 1.3× bigger in the next shot | Zooms a minute |
| Colours | k-means (5) over 4×4 cell colours, seeded from the busiest buckets so it's the same every run | Palette, off by default: the brand kit wins |
| Intro, outro | First or last shot, 0.8–8 s, words on it, nobody talking | Card on or off |
| Music | macOS SoundAnalysis (`version1` classifier) labels speech and music each second; loudness under the voice; beat from an autocorrelated loudness envelope (70–180 bpm) | Music on or off |
| Shape, length | Display size after rotation; duration | Formats, target length (±20%) |
| Hook | Speech in the first second, words in the first second, or a cut in the first 2 s | Shown on the card |

Long videos are read for the first 3 minutes.

## Files

A copied template is an ordinary template folder in `~/Library/Application Support/Vision One/Templates/<id>/`:

```
fast-talking-short/
  template.json   TemplateLook (see BRAND.md)
  style.json      CopiedStyle: the StyleProfile numbers and the ticked traits
```

Anything unticked comes from the built-in look for the same purpose. `CopiedStyle` gives the rest of the app `energy`, `targetSeconds`, `zoomsPerMinute`, `keptPause`, `wantsMusic` and `cardColours`.

On Home, saved templates sit after **Just record**. Picking one sets `ai.nextPurpose` to its purpose and `ai.nextTemplate` to its id.

## Links

YouTube, TikTok, Instagram, X, LinkedIn, Vimeo and Facebook only allow watching, so Vision One never downloads from them (no yt-dlp). `StyleSource` sorts what was pasted: a file or a direct `.mp4`/`.mov` link is read straight away; anything else is **watched as it plays**:

1. The link opens in a Vision One window (`StyleWatcher`, a `WKWebView` that may play with sound). If the page needs a sign-in or a cookie click, do it there; it waits a minute and a half for a video.
2. `StyleWatch.playScript` starts the biggest video on the page from the top, unmuted and not looping. `probeScript` reports its time, size and place on the page four times a second.
3. ScreenCaptureKit captures only that window, cropped to the picture (bars from `object-fit: contain` left out), at 4 fps with 16 kHz mono sound. Frames are measured in memory and stamped with the video's own clock, and only while it plays, so buffering doesn't count as a long shot.
4. It stops at the end, after 3 minutes, when a looping video starts over, or when you press **Stop and use what's read** or close the window.

Needs Screen Recording access, which recording already asks for.

## AI

The scan needs no AI. `StyleNamer` asks the AI ladder (task `style.name`) for a name and a line, sending only `StyleProfile.summaryLines`: numbers, never frames or words from the video. It runs by itself only when the model is on the Mac; a cloud rung waits for **Suggest a name** and the usual approval.

## Still to do

- Template picker in the editor reading `ai.nextTemplate`, and the Editor, zooms and music using `CopiedStyle`'s numbers
- Font guess with Apple's on-device model once it reads images (macOS 27)
- Check on a Mac: scan speed for a 3 minute video, SoundAnalysis labels on real music, whether ScreenCaptureKit hears the web view's sound with a window filter (if not, links read without music and say so), the crop on YouTube and TikTok pages

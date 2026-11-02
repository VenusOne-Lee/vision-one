# Music and sound effects

A music bed that ducks under your voice, and sound effects that follow your cuts. Both live in `sound.json` in the take folder; like `edits.json`, they never change the recording. The editor preview and export lay the same tracks, so what you hear is what you get. Visual overview and research: [Music and Sound Effects](https://claude.ai/artifact/5ifJnEdknHYUr1Rj3ojrrp).

## Where the sounds come from

Nothing ships unless we can redistribute it and builders can use it commercially without credits.

- **Vision One's own pack.** Three music beds (Still water, Workbench, Launch day) and six effects (Whoosh, Pop, Click, Ding, Rise, Thud). There are no audio files in the repo: `SoundSynth` makes each one from a recipe the first time it's needed and caches a WAV in `~/Library/Application Support/Vision One/Sounds`. Bump `SoundLibrary.recipeVersion` when a recipe changes. MIT, like the app.
- **Your own file.** "Choose a file…" takes any audio file. The licence line says it's yours to vouch for.
- **Not used:** Pixabay (no standalone redistribution), YouTube Audio Library (YouTube-only terms), CC BY music as a default (needs a credit in every video), MusicGen (non-commercial weights).
- **Next:** ACE-Step (Apache 2.0) to make music on the Mac from a prompt; optional CC0 downloads (Kenney, Freesound's CC0 filter); ElevenLabs sound effects by prompt with your own key.

## Ducking

Vision One knows when you speak from the transcript, so it draws the music's volume curve ahead of time instead of running a compressor (`MusicEnvelope`, VisionOneKit):

1. Each word's kept part is mapped through the cuts to output time, and words closer than 0.8 s are joined into speech regions (`Speech.outputRegions`).
2. The music sits at its level (default −14 dB) and dips by the duck amount (default 12 dB) over each region, starting 0.25 s before the first word and recovering over 0.6 s after the last. Regions closer than that stay ducked between, so the music never pumps.
3. It fades in over 1 s and out over 2 s.

The curve is a list of points that the app turns into `setVolumeRamp` calls on the music track's `AVAudioMix` parameters.

## Sound effects

Each effect is pinned to a moment of the recording (take seconds), so it moves with the words around it and drops out when its moment is cut. Effects play at −10 dB and lose another 6 dB when they land on speech. Effects that overlap go on separate tracks (`SoundMixPlan` lanes).

The Energy dial suggests effects, dashed until you accept them:

| Energy | Suggests |
| --- | --- |
| Calm | nothing |
| Lively | a whoosh before each new topic (1.2 s or more of silence in the recording), at most one every 25 s |
| Viral | a pop on the first word, and a whoosh on new topics at most every 8 s |

Turning the dial replaces only the suggestions; accepted, rejected and hand-placed effects stay. In the editor, drag an effect along the lane to move it, click a dashed one to use it, right-click to change, play or remove it, or add one at the playhead.

## sound.json

```json
{
  "version": 1,
  "energy": "lively",
  "music": {
    "libraryID": "still-water",
    "title": "Still water",
    "licence": "Vision One original, made in code. Free to use anywhere, no credit needed.",
    "levelDB": -14, "duckDB": 12, "fadeIn": 1, "fadeOut": 2, "loops": true
  },
  "effects": [
    { "id": "…", "soundID": "whoosh", "at": 39.75, "levelDB": -10, "state": "proposed", "isManual": false }
  ]
}
```

A file bed has `filePath` instead of `libraryID`. If the file has moved, the editor says so and the rest of the sound still plays.

## Producer Workspace source levels

`recorded-mix.json` stores recorded microphone and system-audio levels separately (`RecordedMix`). The Sound mix pane saves them with undo/redo and previews them without waiting for a media rebuild. Export applies the same gains, including the gain restored after cut/word-replacement fades. Existing Mute/Solo controls in `LaneMix` remain temporary listening controls and are labelled accordingly.

Energy changes effect suggestions, not vocal delivery or loudness. Voice cleanup, re-saying a line and provider-dependent voice tools remain available through Task tools → Voice tools. Small windows show mixer controls below the video instead of hiding them.

CI's synthetic audio check compares decoded preview and exported signal peaks. This does not replace listening to real voice, music, ducking and replacement audio; see `CLOUD-VERIFICATION.md`.

## Silent-source music verification

Music/effect source assets are retained through composition insertion and export. A selected track that cannot be composed reports an export failure with recovery text instead of silently producing a partial mix. Preview retains the same source assets.

At 208cb79, native CI exported an actual silent import with bundled Still water at −14 dB and checked an audio stream/nonzero decoded samples and preview/export agreement. The tracking assistant independently repeated the real UI export: H264+AAC, 2.5 s, 240000 decoded samples, mean −33.1 dB/max −21.4 dB. These metrics prove nonzero output; subjective music/voice/ducking quality remains open.

Music selection and audition use separate native buttons; actual AX activation selected Workbench and restored Still water. This is scoped accessible-action evidence, not a complete VoiceOver review.

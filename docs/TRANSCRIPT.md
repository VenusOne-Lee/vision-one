# The transcript format

A take with transcribable audio gets `transcript.json` next to `screen.mov`. It is made on the Mac after recording or import. Silent sources retain an editable video and a typed no-audio recovery state instead of a transcript. The editor, filler and pause removal, and captions all read it. The Swift types are in `Sources/VisionOneKit/Transcript.swift`.

## Rules

- **One clock.** Times are seconds from the take's first video frame: the same clock as `screen.mov` and `events.json`.
- **One transcription pass at a time.** Editing never changes `transcript.json`. Cuts and other edits live in their own files (`edits.json`) as time ranges, so running a better model later doesn't break saved edits.
- **Stable ids.** Each word has an integer `id`, unique in the file and in time order. Use ids to point at a word within one transcript; use times for anything saved.
- **Punctuation stays on the word.** `"So,"` and `"release."`. Words are joined with single spaces. `TranscriptWord.normalized` gives `"so"` for matching.
- **Verbatim.** Fillers ("um", "uh", "ja", "eish") are kept as words when the engine hears them, so filler removal can find them. A filler the engine drops still leaves a gap in the timings.
- **Versioned.** `version` is 1. A reader refuses a newer version instead of guessing.

## Example

```json
{
  "version": 1,
  "language": "en",
  "engine": "parakeet-tdt-0.6b-v2",
  "audioTrack": "mic",
  "duration": 4.2,
  "createdAt": "2026-10-27T10:55:01Z",
  "segments": [
    {
      "words": [
        { "id": 0, "text": "So,", "start": 0.42, "end": 0.61, "confidence": 0.93 },
        { "id": 1, "text": "um,", "start": 0.70, "end": 0.95, "confidence": 0.71 },
        { "id": 2, "text": "today", "start": 1.30, "end": 1.62 },
        { "id": 3, "text": "we", "start": 1.62, "end": 1.74 },
        { "id": 4, "text": "ship.", "start": 1.74, "end": 2.10 }
      ]
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `language` | BCP 47 code, such as `en` or `af` |
| `engine` | The model that wrote it, so a take can be re-run with a better one |
| `audioTrack` | `mic` (normal) or `system` |
| `duration` | Length of the audio in seconds |
| `segments` | One per sentence or phrase. The editor shows each as a paragraph |
| `words[].confidence` | 0 to 1, or left out when the engine doesn't give one |
| `words[].speaker` | `S1`, `S2`… when more than one voice was found; left out for solo takes |

## Helpers

`Transcript.read(from:)`, `write(to:)` (validates first), `words` (flat and ordered), `word(id:)`, `word(at:)` for highlighting during playback, `words(from:to:)`, and `gaps(minimum:)` for silences, including before the first word and after the last.

## How it's made

1. Recording stops and `screen.mov` is saved.
2. `Transcriber` (in `App/Sources/Transcriber.swift`) reads the mic track as 16 kHz mono with `AVAssetReader`, before the model is loaded, so a take with no sound fails at once without a download. Each buffer goes where its timestamp says (`SampleTimeline`), so a mic that starts late or drops out turns into silence and every word time still matches the video.
   - **Which track.** `TakeWriter` writes `audio-tracks.json` next to `screen.mov` (`{"version": 1, "tracks": ["system", "mic"]}`, in track order, only the tracks it added). When that file is missing or lists a different number of tracks than the movie has, the channel count decides: the mic is always written mono and system sound stereo.
   - **Fallback.** A take without a mic track uses system sound. So does a take whose mic gave under 1 s of sound (`TakeAudioTracks.minimumMicSeconds`) when system sound gave more.
3. **Parakeet TDT 0.6B v2** runs through [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) on the Neural Engine. It's English only, gives a time for every sub-word token, and does about an hour of audio in 20 to 30 seconds on an M-series Mac. The model (about 0.5 GB) downloads from Hugging Face the first time and is cached after that.
4. `TranscriptBuilder` (in VisionOneKit) joins the tokens into words, keeps punctuation on the word before it, tidies any overlapping or out-of-order times, and splits sentences into segments.
5. `transcript.json` is written atomically. Takes queue one at a time, and any take still missing a transcript is picked up on the next launch (`TakeLibrary.untranscribedTakes()`).
6. A measured mic loudness envelope is saved in levels.json for waveform, voice-level and silence analysis.
7. Cleanup proposals go into `edits.json`, measured against the length of `screen.mov`, not the audio (see [CLEANUP.md](CLEANUP.md)).

The menu shows one muted line while this happens ("Writing the transcript…", "Getting the speech model… 43%"). It's never orange, because orange only means a live recording.

### When it fails

- Failures are kept per take (`TranscriptionFailures`), so a failure isn't lost when the next take starts. The menu shows the newest one, and Retry retries it.
- Every message says how to fix: no sound ("Turn on the mic and record again"), offline on the first model download, Hugging Face busy, a full disk, or a transcript from a newer Vision One.
- A take with no sound can never be transcribed, so it gets `transcript-failed.json` (`TranscriptFailure`: `reason`, `message`, `createdAt`) and launches skip it. Retry in the menu deletes the file and tries again. Other failures, such as a recording that is still saving, are tried again on the next launch.

### Not yet

- Other languages (Afrikaans and others) through WhisperKit, with a filler-keeping prompt
- Checking how many "um"s and "uh"s Parakeet keeps on real takes

## Editor recovery and native text ownership

The pane distinguishes active work from an absent file: queued/running work shows Transcript on its way; a missing file with no job shows No transcript yet and Create transcript. Creation runs on this Mac; the speech model downloads on first use. Read/transcription failures show their explanation and Retry this transcript. A successfully read empty result shows No words found. Playback, timeline edits and export remain available in these recovery states.

The native text coordinator rebinds when another editor model is shown and resets the previous take's selection. Transcript replacement advances a revision counter, so equal-word-count changes rebuild text and character ranges without scanning contents on playback ticks. Word clicks and cuts use the replacement timing. Selection/cut actions write edits.json, not transcript.json.

Native CI mounts the production view, switches A→B→A, checks current-take cuts/undo/redo and saved-byte preservation, then replaces equal-count words/times and checks text/ranges/seek/cut timing. Synthetic native key events also exercise Delete, Undo, Redo and Space with first responder assigned. Real-file missing/corrupt/empty states render inside HarnessView. These checks do not establish OS-wide shortcuts, VoiceOver, real speech-model downloads or transcription quality. See [the full evidence matrix](CLOUD-VERIFICATION.md).

## Silent sources and workspace shortcuts

A permanent `TranscriptFailure.reason.noAudio` becomes the editor's typed `noAudio` state. It offers importing a source with audio or opening recording preparation, rather than retrying an immutable silent file. Genuine transient/corrupt failures retain Retry; a valid empty transcript retains No words found and editing/export. The native silent-source regression passed at 208cb79, and the tracking assistant independently exercised these actions' visible recovery state locally.

The Harness Edit commands resolve the current window/editor undo manager at invocation. An editable native text/field editor retains its own typing history. Real local 7869fb6 canvas Cmd-Z/Cmd-Shift-Z and focused Ask typing undo/redo passed. The whole-Harness synthetic task-switch/key/field fixture passed at 5f0fbab / CI40953770394; the older transcript-only synthetic test never established full canvas shortcut acceptance.

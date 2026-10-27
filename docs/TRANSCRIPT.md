# The transcript format

Every take gets a `transcript.json` next to `screen.mov`. It is made on the Mac, from the mic track, after you stop recording. The editor, filler and pause removal, and captions all read it. The Swift types are in `Sources/VisionOneKit/Transcript.swift`.

## Rules

- **One clock.** Times are seconds from the take's first video frame: the same clock as `screen.mov` and `events.json`.
- **Written once.** Editing never changes `transcript.json`. Cuts and other edits live in their own files (`edits.json`) as time ranges, so running a better model later doesn't break saved edits.
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

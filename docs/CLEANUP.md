# Fillers and long pauses

After a take is transcribed, Vision One proposes cuts for fillers, stutters and long pauses. Nothing is cut until you accept it: proposals are drawn dashed, accepted cuts solid, and cut words stay visible with a line through. The logic is in `Sources/VisionOneKit/Cleanup/`.

## What it proposes

| Reason | What | Rule |
| --- | --- | --- |
| `filler` | um, uh, er, hmm in any spelling ("ummm") | Always |
| `filler` | like, so, you know, I mean, basically, actually, okay; South African ja, yah, ag, eish, yoh, haai, sho | Only when it stands alone: a pause or punctuation on both sides ("So, today", "ja, so") |
| `filler` | ne, neh, hey as a tag ("it's lekker, hey.") | Only at the end of a sentence, never first ("Hey, everyone" stays) |
| `repeat` | "the the", "I I I" | Keeps the last one. "that that", "now now" and a few others stay |
| `pause` | A gap of 1 s or more between words | Shortened to 0.4 s, not removed |
| `deadAir` | Silence before the first word and after the last | Trimmed to 0.25 s |

Never proposed, because they carry meaning in South African English: "now now", "just now", "shame", "is it".

## How it works

1. Read `transcript.json` (see [TRANSCRIPT.md](TRANSCRIPT.md)). Words are matched on `FillerLexicon.normalize`: lowercased, accents folded, punctuation trimmed.
2. A filler cut runs from the start of the filler to 50 ms before the next word, so "I was, um, going" closes up to "I was, going".
3. Word timestamps drift into silence, so when the mic loudness is available (`LoudnessEnvelope`, 10 ms RMS levels in dBFS) a pause is only cut inside the longest quiet run in the gap. The quiet threshold sits 12 dB above the take's noise floor. A gap where someone is talking but the transcript missed it is left alone.
4. Cuts that overlap or sit less than 50 ms apart are merged, so "Ja, um," is one proposal.
5. After the transcript is written, the app measures the mic loudness and calls `AutoClean.run(on:transcript:loudness:)`, which uses `EditList.propose(_:)` to add the proposals to `edits.json` as cuts with state `proposed`, skipping any that overlap a cut already there, including ones you rejected, so running it again never brings them back.

All thresholds are in `CleanupSettings`, and the word list is data in `FillerLexicon.standard`, so more languages can be added without code.

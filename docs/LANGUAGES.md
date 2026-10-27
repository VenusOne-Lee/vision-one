# South African languages

Captions in all eleven spoken official languages. Open it from the globe button in the editor. Scribe (a take spoken in another language) and an optional AI dub come next, once the voice coach's ElevenLabs client is on main; they're designed below. Visual overview and research: [Versions and languages](https://claude.ai/artifact/6ZTgVYocinRVTqByVuU18K).

## What each engine can do

Checked against each provider's own documentation on 27 October 2026. "Good" means usable as is; "fair" means a speaker should read it before you post; "rough" means treat it as a first draft.

| Language | On the Mac (Parakeet) | ElevenLabs Scribe | Translation (your AI rung) | ElevenLabs dub | ElevenLabs voice |
| --- | --- | --- | --- | --- | --- |
| English | good | good | good | yes | yes |
| Afrikaans | no | good (10–20% WER) | good | yes | yes |
| isiZulu | no | moderate (25–50% WER) | fair | yes | no |
| isiXhosa | no | moderate | fair | **no** | no |
| Sepedi | no | moderate | fair | yes | no |
| Sesotho | no | no | fair | yes | no |
| Setswana | no | no | fair | yes | no |
| Xitsonga | no | no | rough | yes | no |
| siSwati | no | no | rough | yes | no |
| Tshivenḓa | no | no | rough | yes | no |
| isiNdebele | no | no | rough | **no** | no |

The translation column is our estimate from published benchmarks, not a provider promise. The table lives in code as `LanguageSupport.of(_:)` (VisionOneKit), so the app and this page say the same thing; update both when a provider changes.

Also looked at and not used yet: Whisper (Afrikaans only; isiZulu around 93% WER), Apple Translation (no South African language besides English), Google Translate (all eleven, needs a Cloud key), Lelapa Vulavula (af, zu, st, en; a good fit for later), Google Chirp 3 (af, zu, xh, nso, preview), Meta Omnilingual ASR (every language, Apache 2.0, not ready to run on a Mac). South African Sign Language became the twelfth official language in 2023; no engine here supports it, so Vision One makes no claim about it.

## Captions in another language

1. `CaptionTranslator` splits the transcript into sentences and sends them in batches of about 6,000 characters through the AI ladder (task `captions.translate`). Apple's on-device rung is skipped because it doesn't write these languages. The ladder asks before anything leaves the Mac, as always.
2. Brand names, caption keywords and a short list of South African names (Joburg, Mzansi, SnapScan…) are passed as "never translate".
3. Each translated sentence keeps its source start and end, and its words are spread across that time by length (`Transcript.translated`). That makes a normal transcript, so cuts, caption styles, burn-in and .srt/.vtt all work unchanged.
4. Files in the take folder: `translation.<code>.json` (the lines, with the source sentence and an `edited` flag) and `transcript.<code>.json` (the timed words). Lines marked edited are kept on the next translation and never sent again.

`captions.json` gains `language`: the language burned into the video (none means as spoken). Every other ready language is written beside the export as `<name>.<code>.srt` and `.vtt`.

## A take spoken in another language (next)

Parakeet only knows English. "Spoken in another language" sends the voice (never the screen) to ElevenLabs Scribe (`scribe_v2`, word timestamps) with your own key and replaces `transcript.json`. The Parakeet transcript is kept as `transcript.parakeet.json`.

## Dubbing (next)

Made from your newest export, so music and cuts match. Only its sound is sent to ElevenLabs Dubbing; the dubbed audio comes back and is put on the original video without re-encoding it, as `<export>.<code>.mp4`, with the audio kept as `dub.<code>.m4a` in the take folder. Free ElevenLabs plans add a watermark. Not offered for isiXhosa or isiNdebele. The voice is AI-made from yours, and the app says so.

## Fillers

`FillerLexicon.lexicon(for:)` gives the filler words for each language, for cleanup and the voice coach: "eish", "yoh", "sho" and a trailing "neh" in English; "jy weet", "basies", "nou ja", "ag" in Afrikaans; "uyabona", "yazi", "phela", "angithi" in isiZulu.

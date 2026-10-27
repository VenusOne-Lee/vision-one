# Voice and script coach

Helps before you record: the script coach reads your script, Rehearse runs a practice take with live meters, and optional ElevenLabs tools read the script aloud, talk it through with you, and clean or fix your voice afterwards. The on-device parts are free and send nothing anywhere. ElevenLabs uses your own key and asks before anything leaves the Mac. Logic lives in `Sources/VisionOneKit/Coach/`, and it builds on the shared `Script` and `ScriptFollower` in `Sources/VisionOneKit/Script/`.

## Script coach (`ScriptCoach`, on the Mac)

`ScriptCoach().check(script, pace:target:)` returns a `ScriptReport`: dashed `ScriptFlag`s per line, plus a `ScriptLength`.

| Flag | Rule | One-click fix |
| --- | --- | --- |
| Long sentence | More than 22 words | Split at the ", and" or comma nearest the middle |
| Tongue-twister | A word repeating the end of the previous one ("SnapScan scan"), or 3 of 4 words starting with the same hard sound | Drop the repeat |
| Jargon / Mouthful | An unknown acronym of 3+ letters, or a word of 7+ syllables | (model rewrite) |
| Big number | 5+ digits | "R1.25 million", "about 48,000" |
| Slow opening | First line over 14 words | (model rewrite) |
| Ending | Last line has no ask (try, visit, a link, a question…) | (model rewrite) |

`rewriteRequest` asks any AI rung (Apple's on-device model is enough) for easier ways to say the flagged lines; `applying(_:to:)` puts them on the flags. `Script.applying(flag)` applies one fix.

**Length** is words ÷ your pace, plus 0.35 s between lines and the pauses in audio tags. `SpeakingPace.learn(from:)` takes the median words a minute of your past takes, counting only time spent talking; until there's a take it uses 150.

## Rehearse (`RehearsalMonitor`, `CoachNotes`, on the Mac)

A practice run is never saved as a take. The app feeds `RehearsalMonitor` live words from on-device speech recognition (`setWords`, the whole list each time) and mic frames (`add(VoiceFrame)`: level in dB plus pitch from `PitchTracker`, a YIN estimator).

| Meter | How | Default band |
| --- | --- | --- |
| Pace | Words a minute over the last 12 s of talk; hesitations don't count | 130–165 (Speaker Coach's range), moved to sit around your own pace once learned |
| Ums | Hesitations from `FillerLexicon` | under 2 a minute |
| Energy | Half loudness spread (2–9 dB), half pitch spread (1–5 semitones) over 6 s | Lively (0.5–0.85) |
| Pauses | Mean gap between words, counting 0.25–4 s | 0.3–0.9 s |

After the run, `CoachNotes.review` matches heard words to lines with `ScriptFollower` (so retakes count toward their line) and picks at most two fixes and one thing to keep: too fast or slow on a line, ums, a long pause, a flat line, or a skipped line, and then a strong opening, strong ending or good pace. Each note has a time so the app can play that moment back.

## ElevenLabs (optional, your key)

`ElevenLabsClient` (key in the Keychain as `elevenlabs-api-key`). Every call that carries your words or voice goes through `OutboundGate` first. Voice calls use the new `.audio` kind: the sheet says it sends your voice and never your screen, and "Allow for this session" works for them as it does for text. Listing voices and credits sends only the key.

| Feature | Endpoint | What's sent |
| --- | --- | --- |
| Hear it first | `POST /v1/text-to-speech/{voice}/with-timestamps`, `eleven_v4` | The script text, with audio tags from `DeliveryMarkup` (tone tag, `[pause]` between paragraphs, `[slower]` before long lines). Character timings become word timings so the script lights up as it's read. Without a key, an Apple voice reads `DeliveryMarkup.plain`. |
| Talk it through | `POST /v1/convai/agents/create` once, then `GET /v1/convai/conversation/get-signed-url` per talk | The agent's prompt (`CoachAgentConfig`) reads `{{script}}`, `{{notes}}` and `{{focus}}` dynamic variables, sent in the first WebSocket message. Mic audio is streamed as 16 kHz PCM16 while the talk is open. Wire format in `CoachWire`. |
| Voice isolator | `POST /v1/audio-isolation` | The take's mic track only |
| Voice clone | `POST /v1/voices/add` | Your own takes, after a consent sheet |
| Fix a word | text to speech with your cloned voice | One word |

## voice.json

`VoiceEdits` per take: `cleanVoice` (the isolated mic track, kept or not) and `fixes` (`WordFix`: the word, the new audio file, the voice, kept or not). Everything starts proposed (dashed) and can be undone. `aiSpokenWordIDs` lets the transcript mark every AI-spoken word. `placements(on:)` gives export where each kept fix plays and which span of the original mic to mute; a word split by a cut is left alone. `disclosure` is a line export can add to the description.

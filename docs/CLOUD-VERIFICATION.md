# Producer Workspace cloud continuation: acceptance evidence

The complete scope remains [FULL-OVERHAUL-PLAN.md](FULL-OVERHAUL-PLAN.md). No requirement is considered fully accepted merely because its code or unit tests exist. This is an unfinished draft PR, not a completion certificate.

## Environment and source

- Started from `codex/producer-workspace-overhaul`, `e5ac6c4a5f2302d7a318c42e2cfc78018f1bbd8b`.
- Read the full plan and workspace update; inspected all seven actual approved PNGs before implementation.
- Cloud executor: Linux x86_64, no Swift, Xcode, macOS native UI or capture devices. GitHub repository APIs and source checkout are available. Native builds/tests run through existing macOS CI. No work has been started on the user's Mac.
- Draft PR: https://github.com/VenusOne-Lee/vision-one/pull/76. No merge, release, deployment or outbound message has been performed.

## Current authoritative CI evidence

| Commit | Evidence | Result and limit |
| --- | --- | --- |
| `02294fa` | [CI 40908108473](https://github.com/VenusOne-Lee/vision-one/actions/runs/40908108473) | 825 tests, one failing macOS `/var` vs `/private/var` alias assertion in the new import test. Native build skipped. Fixed canonical comparison while retaining byte/title/source assertions. |
| `2b5acd3` | [CI 40908816967](https://github.com/VenusOne-Lee/vision-one/actions/runs/40908816967) | 827 tests passed. Native build failed on a closure capturing `desk` before its declaration. Fixed in next commit. |
| `467f9eb` | [CI 40909823202](https://github.com/VenusOne-Lee/vision-one/actions/runs/40909823202) | 830 package tests passed; native Xcode Debug build succeeded. These results apply only to this commit. No rendered-media check was present in this revision. |
| `67fb919` | [CI 40910423885](https://github.com/VenusOne-Lee/vision-one/actions/runs/40910423885) | Package step passed. Native build failed on a main-actor default-closure annotation in the mic-probe injection hook. Media check skipped. Fixed in next commit. |

| `9ed42b6` | [CI 40911299289](https://github.com/VenusOne-Lee/vision-one/actions/runs/40911299289) | 831 tests, four failures because share-target preference lists omitted the new portrait preset. Fixed lists without weakening coverage assertions. Native build/media skipped. |

| `2bfa9fd` | [CI 40912074709](https://github.com/VenusOne-Lee/vision-one/actions/runs/40912074709) | 832 tests and native Debug build passed. Media fixture setup failed before product rendering; retained files inspected with ffprobe. |
| `9dd75c2` | [CI 40913230390](https://github.com/VenusOne-Lee/vision-one/actions/runs/40913230390) | 833 tests and native build passed. Fixture setup succeeded; product render failed with AVFoundation -11800 / underlying -12780. Source/camera asset lifetimes retained in the next diagnostic revision. |
| `aa18925` | [CI 40914321446](https://github.com/VenusOne-Lee/vision-one/actions/runs/40914321446) | 834 tests, native Debug build and rendered-media checks passed. Downloaded artifact 12915920866; decoded PNGs inspected; independent ffprobe and full ffmpeg decode passed. [Metrics and hashes](verification/aa18925-media.json). |
| `5e30c03` | [CI 40914740051](https://github.com/VenusOne-Lee/vision-one/actions/runs/40914740051) | 835 tests, native Debug build and media diagnostic passed. The later expanded-format/silent-import checks are not covered by this revision. |

| `8b33538` | [CI 40915635962](https://github.com/VenusOne-Lee/vision-one/actions/runs/40915635962) | 835 tests, native build and expanded format/silent-import media checks passed; downloaded artifact inspected and independently decoded. [Metrics](verification/8b33538-media.json). |
| `1ae065a` | [CI 40917472492](https://github.com/VenusOne-Lee/vision-one/actions/runs/40917472492) | Package/native build passed; new rotated-import assertion failed. Native reference and export PNGs showed reversed red/blue orientation. |
| `57f187f` | [CI 40918958357](https://github.com/VenusOne-Lee/vision-one/actions/runs/40918958357) | 836 tests, native build, media checks (including unchanged rotation assertion) and 20 native renders passed. All 20 images inspected; concrete layout failures recorded, not accepted as finished. |
| `4287bb5` | [CI 40919869271](https://github.com/VenusOne-Lee/vision-one/actions/runs/40919869271) | Package, native build, media and expanded 60-render steps passed. Inspection in progress; AVPlayer black areas limit this revision's visual evidence. |

Later commits require their own CI results. Preserve the historical local 821-test/build and `e5ac6c4` theme/build evidence as historical only.

## Requirement-by-requirement status

| # | Implemented or retained code | Evidence still needed before full acceptance |
| --- | --- | --- |
| 1 Recording | `RecordingPreparationView`: shared source controls, source snapshot, selected-mic test, permission state, countdown/script, one primary Record action. Per-project recording choices. Original pause/resume/stop/restart and camera capture retained. | Actual screen/window/area/camera capture; allow/deny/reconnect transitions; short-display and keyboard walkthrough; correct stopped task and saved media. Fake-probe race check does not validate hardware. |
| 2 New task/library/import | Four productive starting actions, resume/default summary, File/Library import, cancellable owned copy transaction. AVFoundation validates readable non-empty video, including silent video. Existing sorting/search/rename/trash recovery retained. | Actual import picker, cancellation timing, rotated/invalid/no-audio media editing and export, archive/recovery UI. Copy/cancel tests do not establish these. |
| 3 Requests/review | Await take resolution before navigation/submission; preserve per-page drafts; clarify unknown requests. Editor ask routes through task plans and approvals. Exact navigation opens tools. Completed activity is collapsed after the conversation. | Native navigation/race/approval/retry/cancel walkthrough; external/on-device provider gates; compound requests and alternate versions on real tasks. |
| 4 Transcript/cleanup | Existing timed transcript, playhead, proposed cuts, keep/apply, undo/redo and before/after preserved. Copied cleanup rhythm feeds proposals. | Real transcript loading/missing/failure states; word/timeline synchronisation; before/after and undo/redo with concurrent agent edits. |
| 5 Expanded editor | Selected horizontal tool row, left task rail, canvas/transcript composition, full-width timeline/ask; existing captions/zoom/blur/draw/voice/version controls preserved. Narrow transport now wraps. | Selected-layout comparison, resizing, keyboard/focus navigation, return to same task and rotated imports. |
| 6 Sound | Saved source levels used in preview/export; existing music/ducking/effects retained. Energy describes effect suggestions. Mixer remains reachable in narrow windows. | Synthetic saved-source preview/export peaks agree (0.12538 vs 0.13038, AAC encoding tolerance) at the commits above. Audible real voice/music/ducking/replacements and saved levels/undo/redo in native UI remain open. |
| 7 Clips/thumbnails | Shared moving reframe plan; fixed/fit preserved; camera/caption/brand composition; timed sidecar warnings; batch/cancel/retry indicators; preview actual MP4. Existing thumbnail tooling retained. | The synthetic portrait MP4 has passed native decode/pixel/audio/timed-sidecar checks and cloud visual inspection at the commits above. Latest-head and expanded-format checks still require results. Real footage, camera placement across varied sources and audible music/voice acceptance remain open. |
| 8 Templates/defaults | Picker loads built-ins/user templates; take-owned template/style/cards snapshot; project settings; once-only marker checked before writes; rollback on failure. Captions, purpose/Energy/target, output formats, cleanup rhythm and card/watermark flags wired. | Real template/project UI and export walkthrough. Copied zoom frequency now limits new proposals and copied card palette respects brand paper/ink overrides; these newer paths need their own regression/native evidence. |
| 9 Preparation/automation | Contextual native Task Tools cards show prerequisites and retain task context; Script Coach/rehearsal route through recording preparation; voice/language handoff and Autopilot prerequisites improved. Advanced functions preserved. | Coherent native walkthrough of each existing advanced surface, setup prerequisites and accurate provider requirements. These screens have not all had visual acceptance in cloud. |
| 10 Delivery | Multi-take serial batches, per-take cancel/retry/results and saved-setting semantics; 4:5 preset; existing Cloudflare/social handoff/languages/personalised versions retained and reachable. | Multi-take queue UI and failure/cancel races; full-video/clip preview; actual share handoff, language/provider prerequisites. In-memory queue is not restart-persistent. |
| 11 Theme/accessibility | Shared theme tokens used; removed forced-light caption popover; existing appearance preservation retained; adaptive recording height and mixer pane; labelled new controls. | Native light/dark parity on every changed surface, contrast/VoiceOver/focus/reduced-motion/small-window walkthrough. Native CI screenshots now exist, with observed issues and fixes tracked in [the visual review](verification/WORKSPACE-VISUAL-REVIEW.md). Static renders do not establish interactive accessibility. |
| 12 Verification/docs | Relevant regression tests; macOS CI builds; diagnostic render/decode path and retained media artifacts added; feature docs updated against owning code. | Current-head package/build/media results, inspection of generated MP4/PNG/audio, complete native walkthrough and resolution of every remaining row. |

## Native workspace visual diagnostic

`--verify-workspace` renders production SwiftUI states with an isolated Desk/take fixture in light/dark and wide/narrow sizes. Advanced tools are static: no recording, practice, provider request or MCP server is started. Use a clean CI account because advanced models read that account's settings. The later verification-only player fallback decodes a frame through the actual AVPlayerItem composition; it is explicitly not evidence of live player layers. [Visual findings and fixes](verification/WORKSPACE-VISUAL-REVIEW.md) remain part of the acceptance work, including non-hardware design gaps.

## Native media diagnostic

`MediaVerification` creates a synthetic screen, separate green camera, tone audio, word-timed transcript and accepted cut; renders a portrait MP4 with captions and an overlay; decodes frames/audio; checks dimensions/duration, camera/caption/overlay pixels and subtitle timing. It validates invalid and silent import assets and a delayed mic-probe cancellation without access to real devices. CI preserves the output folder as `media-verification` even on failures when files exist.

Cloud visual inspection of the retained synthetic portrait frames confirmed the camera stays fully within the upper-right output, captions are legible, the overlay survives, and framing moves from the red source region toward blue. Independent FFmpeg inspection confirmed H.264 1080×1920 and AAC stereo 48 kHz, both 2.5 seconds, with no full-decode errors. The SRT starts its cues at 0.2 and 1.1 seconds after the accepted cut. This closes only those fixture assertions.

Real footage and an interactive macOS session must still establish actual audio quality, broader camera/framing/rotation behaviour, theme/accessibility and complete user workflows. The current Linux session has no interactive macOS surface or capture devices. The PR stays draft; the full goal remains unfinished.

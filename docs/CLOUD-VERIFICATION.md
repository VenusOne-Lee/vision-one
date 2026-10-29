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

Later commits require their own CI results. Preserve the historical local 821-test/build and `e5ac6c4` theme/build evidence as historical only.

## Requirement-by-requirement status

| # | Implemented or retained code | Evidence still needed before full acceptance |
| --- | --- | --- |
| 1 Recording | `RecordingPreparationView`: shared source controls, source snapshot, selected-mic test, permission state, countdown/script, one primary Record action. Per-project recording choices. Original pause/resume/stop/restart and camera capture retained. | Actual screen/window/area/camera capture; allow/deny/reconnect transitions; short-display and keyboard walkthrough; correct stopped task and saved media. Fake-probe race check does not validate hardware. |
| 2 New task/library/import | Four productive starting actions, resume/default summary, File/Library import, cancellable owned copy transaction. AVFoundation validates readable non-empty video, including silent video. Existing sorting/search/rename/trash recovery retained. | Actual import picker, cancellation timing, rotated/invalid/no-audio media editing and export, archive/recovery UI. Copy/cancel tests do not establish these. |
| 3 Requests/review | Await take resolution before navigation/submission; preserve per-page drafts; clarify unknown requests. Editor ask routes through task plans and approvals. Exact navigation opens tools. Completed activity is collapsed after the conversation. | Native navigation/race/approval/retry/cancel walkthrough; external/on-device provider gates; compound requests and alternate versions on real tasks. |
| 4 Transcript/cleanup | Existing timed transcript, playhead, proposed cuts, keep/apply, undo/redo and before/after preserved. Copied cleanup rhythm feeds proposals. | Real transcript loading/missing/failure states; word/timeline synchronisation; before/after and undo/redo with concurrent agent edits. |
| 5 Expanded editor | Existing captions/zoom/blur/draw/voice/version controls retained. Correct task opening; constrained panes; camera preview uses export compositor. | Selected-layout comparison, resizing, keyboard/focus navigation, return to same task and rotated imports. |
| 6 Sound | Saved source levels used in preview/export; existing music/ducking/effects retained. Energy describes effect suggestions. Mixer remains reachable in narrow windows. | Decode/compare synthetic preview/export audio; audible real voice/music/ducking/replacements; saved levels and undo/redo in UI. |
| 7 Clips/thumbnails | Shared moving reframe plan; fixed/fit preserved; camera/caption/brand composition; timed sidecar warnings; batch/cancel/retry indicators; preview actual MP4. Existing thumbnail tooling retained. | Actual decoded CI media result plus human inspection of portrait camera placement, cuts/caption timing, sound and real footage. Fixture checks cover only their listed assertions. |
| 8 Templates/defaults | Picker loads built-ins/user templates; take-owned template/style/cards snapshot; project settings; once-only marker checked before writes; rollback on failure. Captions, purpose/Energy/target, output formats, cleanup rhythm and card/watermark flags wired. | Real template/project UI and export walkthrough. Copied palette and zoom-frequency traits remain reference metadata, explicitly labelled; full trait application is unfinished. |
| 9 Preparation/automation | Task tools links Script Coach, rehearsal, voice tools, Autopilot, agent/MCP settings without dropping task context. Existing functionality retained. | Coherent native walkthrough of each existing advanced surface, setup prerequisites and accurate provider requirements. These screens have not all had visual acceptance in cloud. |
| 10 Delivery | Multi-take serial batches, per-take cancel/retry/results and saved-setting semantics; 4:5 preset; existing Cloudflare/social handoff/languages/personalised versions retained and reachable. | Multi-take queue UI and failure/cancel races; full-video/clip preview; actual share handoff, language/provider prerequisites. In-memory queue is not restart-persistent. |
| 11 Theme/accessibility | Shared theme tokens used; removed forced-light caption popover; existing appearance preservation retained; adaptive recording height and mixer pane; labelled new controls. | Native light/dark parity on every changed surface, contrast/VoiceOver/focus/reduced-motion/small-window walkthrough. No new native screenshots have been captured in cloud. |
| 12 Verification/docs | Relevant regression tests; macOS CI builds; diagnostic render/decode path and retained media artifacts added; feature docs updated against owning code. | Current-head package/build/media results, inspection of generated MP4/PNG/audio, complete native walkthrough and resolution of every remaining row. |

## Native media diagnostic

`MediaVerification` creates a synthetic screen, separate green camera, tone audio, word-timed transcript and accepted cut; renders a portrait MP4 with captions and an overlay; decodes frames/audio; checks dimensions/duration, camera/caption/overlay pixels and subtitle timing. It validates invalid and silent import assets and a delayed mic-probe cancellation without access to real devices. CI preserves the output folder as `media-verification` even on failures when files exist.

Human inspection must still judge framing, readability, actual audio quality and the real user workflows. A green diagnostic does not close those gates.

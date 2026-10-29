# Native workspace visual review (unfinished)

The seven approved PNGs remain the visual targets. This is fixture evidence, not hardware, playback, keyboard or VoiceOver acceptance.

## Baseline: 57f187f / CI 40918958357

All 20 PNGs in artifact 12917358429 were opened and inspected: new-task, task, editor, sound and delivery, each light/dark and 1512×982 / 900×640. Tests (836), native build, media diagnostic and screenshot generation passed. Generation alone did not establish acceptance.

Observed findings:

- New Task wide: productive four-card start and right defaults/recent/source rail present in both appearances. Narrow: three tall cards plus a fourth row put the composer below the initial viewport. Changed to compact 2×2 and composer before suggestions.
- Task wide: conversation/preview/transcript hierarchy matches the selected family. Narrow stacked layout squeezed the video to a small rectangle. Changed to explicit Task/Review switching.
- Editor: horizontal tools present, but timeline and ask remained confined to the canvas column; narrow transport clipped timecode and the version selector. Moved timeline/ask below both canvas and transcript; transport now wraps into rows and keeps accessory labels scrollable.
- Sound: narrow Energy compressed into an empty tall pill; preview occupied too little of the large canvas. Moved mixer beside the expanding preview, tracks underneath, restored sidebar context, preserved Energy's intrinsic labels and used Preview/Mix switching at narrow widths.
- Delivery: existing clip cards occupied only the top of a mostly empty pane. Added a dedicated large selected rendered preview, labeled formats/captions/export/status, and related handoffs; candidates and post-copy tooling sit in the conversation.
- All AVPlayer rectangles were black in bitmap caching. Those images establish controls/layout only. A verification-only decoded-frame fallback from the actual AVPlayerItem and video composition is being added; it is not live-player evidence. Separate actual MP4 assertions remain mandatory.

## Expanded baseline: 4287bb5 / CI 40919869271

Package/native/media/render steps passed; artifact 12918306458 contains 60 PNGs. Inspection is in progress, not blanket acceptance. Coverage adds recording preparation, task tools, Script Coach, rehearsal, voice tools, Autopilot, agents, pending plans, failure and loading.

Inspected findings so far:

- Recording at short height retains header/footer/Record and scrolls source/audio/script controls. Source placeholder honestly identifies absent preview; real source/device/permissions checks remain open.
- Task tools shows prerequisites before opening separate native windows and retains current task context.
- Script Coach and rehearsal show script and contextual analysis/meters with readable narrow controls. Voice tools show external-provider setup before sending; the stale “dubbing coming later” card is being replaced with the actual Languages entry point.
- Autopilot empty state has a clear action; prerequisites need an early header and Access settings link.
- Standalone Agents capture inherited a transparent background. Capture root needs the normal themed background and exact requested frame. Enabled setup content can render without starting the MCP server.
- Wide pending plans show review options and numbered keyboard hints; failed requests show a useful explanation and Retry. Loading is represented by the production progress state. Narrow pending/error fixtures must explicitly show the Task pane after the adaptive layout change.
- Narrow Sound's stacked preview/mixer leaves too little usable mixer height. Switch Preview/Mix instead of squeezing both.

Every later revision needs its own build/render results and image inspection. Interactive resizing, focus, shortcuts, reduced motion, real captures and permissions, external provider gates, audible mix and real share handoffs remain unfinished.

## Finishing layout: bf66a8d / CI 40920814329

Native build, media and 60-render steps passed. Inspected new-task-light-narrow, editor-dark-narrow, sound-dark-wide, delivery-light-wide and task-dark-wide. Composer is now above suggestions at 900×640; transport shows the complete version label on its own row; full-width editor timeline and left task rail are present. Delivery has a large selected render and direct labeled output controls, candidates/post tools at left and related finishing actions below. The AVPlayerItem fixture fallback produces visible composition frames.

The delivery screenshot still sampled the first keyframe, omitting the later camera/caption. Independently decoded its actual clip MP4 at 0.5 seconds with FFmpeg: camera and caption are present and correctly placed. The screenshot fallback was changed to zero time tolerance and a required decoded-frame check; it must not pass if a required fixture frame is missing.

## Context refinement: ec8dae2 / CI 40921775137

Package/native/media/render steps passed. Inspected agents-dark-narrow, recording-light-narrow, sound-light-narrow, pending-dark-narrow, task-light-wide and autopilot-dark-wide. The agent capture now has an opaque themed background and real setup controls without starting MCP. Recording header/footer remain within the requested 900×640 capture with internal scrolling. Narrow mixer and pending approval are reachable at full pane width. Transcript paragraphs, accepted cuts and captions now use a richer isolated fixture; Autopilot displays prerequisites and an Access settings route.

These are named inspected states, not an assertion that all 60 images or every advanced interaction are accepted. The exact-frame follow-up and later code require their own current evidence.

## Complete static set: 859180f / CI 40923474305

All **66** PNGs in artifact **12919422422** were opened individually and visually inspected, not just generated. Coverage is 15 states × two appearances × wide/narrow, plus new task/editor/sound at the 760×520 window minimum. [Per-image dimensions and SHA-256](859180f-workspace.json) identify the inspected files. CI ran 838 package tests, native build, media and screenshot checks successfully, including current-settings caption-toggle regressions and the native notification/reopen check.

Comparison with the approved family:

| Approved target | Observed native result | Limit / follow-up |
| --- | --- | --- |
| 01 task light / 04 task dark | Compact sidebar, concise thread, larger preview/transcript; readable pending and failed states; narrow Task/Review switch | Static fixture only; no live provider/keyboard/VoiceOver walkthrough |
| 02 new task | Four productive actions, wide defaults/recent/source rail, compact 2×2 and initially reachable composer at both smaller sizes | Source/default editing and record/import pickers still need interaction acceptance |
| 03 recording preparation | Unified source/audio/camera/mic/script/countdown controls in an adaptive sheet; one Record action; persistent header/footer and scroll area | Permission-safe static source placeholder, not actual screen/camera preview or capture evidence; lower controls require scroll interaction acceptance |
| 05 expanded editor | Horizontal tools, left task context rail, large canvas/transcript, full-width timeline/composer, wrapping transport | Optional panels collapse primary Transcript/Changes into a menu; fixed in subsequent revision, inspect its images |
| 06 sound | Expanding preview, adjacent mixer, readable Energy, source gains, music/effects and lanes; narrow Preview/Mix switch | At minimum height optional tracks crowd the mixer; subsequent revision defaults them closed with Show tracks; inspect its images. No audible acceptance |
| 07 finishing | Large selected actual clip render with camera/captions, labeled format/caption/export controls, candidates/post tooling and related handoffs | Last rendered file requires rerender after edits, explicitly labeled. Real share/provider flows remain unverified |
| Advanced tool family | All four size/appearance combinations inspected for task tools, Script Coach, rehearsal, voice tools, Autopilot and agents. Consistent tokens, clear prerequisites, provider-disabled actions and readable idle/setup content | Does not accept running capture/rehearsal/Autopilot, voice-provider proposals or connected-agent activity |

No new clipping was observed in this set beyond the minimum-height mixer issue. The 760×520 editor's roughly 80px preview was insufficient for useful caption review. The follow-up closes the timeline by default at that height and uses a compact transport, with Show timeline and Details keeping controls reachable. Its actual minimum-size images must be inspected before accepting the fix. Static observation is not a substitute for interactive usability testing.

## Caption ownership and separate audio sources

`0ac14f2` / CI 40924522042 passed package/native/media/render checks. The native diagnostic mounts the actual HarnessView with Clips active, switches A→B→A, checks the mounted caption state owner, toggles B, preserves its current language/style, and verifies A's settings bytes are unchanged. The visibility helper also preserves unreadable settings by failing rather than replacing them with defaults.

The expanded media diagnostic uses two distinct tone tracks, with system audio deliberately first and microphone second, to check source identity and independent saved gains. Actual exported audio and editor-preview audio are decoded and compared. Synthetic audio evidence does not establish real audible quality, provider replacement audio or capture hardware.

## Minimum mixer follow-up: 3f3f470 / CI 40924902600

Inspected sound-light-minimum, sound-dark-minimum, sound-light-narrow and sound-dark-wide. At 760×520, Energy, voice clarity, mic/system gains, Show tracks and composer are visible. At larger sizes, optional tracks remain available below the mixer/preview. Independent FFmpeg full decode passed for all ten valid MP4 files in artifact 12919838385; the intentional invalid-import fixture was excluded. [Metrics and file hashes](3f3f470-media.json) record microphone export/preview peaks 0.25801/0.25007 and system peaks 0.10354/0.10022.

The next minimum-editor change uses a one-row compact transport and defaults the timeline closed, with visible Details and Show timeline controls. Its preview size must be verified in the generated minimum images. A newly identified clip-card wiring gap is also fixed: clip export now passes the same template-aware CardMaker as the full-video queue. A native owned-HTML-asset render check is added; results are pending for that revision.

## Compact editor and populated Library follow-up

For `2b22376` / CI 40927817878, editor light/dark minimum and editor dark narrow/light wide were opened. At 760×520 the preview is now roughly 241px high, captions are readable, and playback, Details, Show timeline and Ask remain visible. The earlier ~80px viewport finding is resolved in static evidence. The user independently confirmed the minimum images from the later card-fixture run.

For `27fafb9` / CI 40929007554, the user opened all four populated Library light/dark × wide/narrow images. Fixture rows/thumbnails, import, search/filter/sort were visible; no clipped actionable control was observed at 900×640 or 1512×982. The search placeholder truncates at 900px but remains usable. This does not verify empty recovery, rename failure, focus/hover menus or the 760×520 Library.

The connector recovery adds filtered-empty and minimum Library captures. Their generation and inspection remain pending. Reduce Motion has conditional source and native transaction checks; screenshots do not verify animation behavior.

For `1b5c2bf` / successful CI 40933978656, the user downloaded and inspected owned-template-intro.png and owned-template-body.png. The actual yellow/blue SVG fills the portrait output without black letterboxing, and the post-intro body retains a fully visible upper-right camera plus readable Producer caption. This accepts only the named synthetic template fixture, not general footage or interactive template application.

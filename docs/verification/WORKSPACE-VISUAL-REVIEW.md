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

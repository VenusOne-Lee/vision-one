# Producer Workspace: match the pictures

Lee picked the seven pictures in this folder (2 Nov 2026) as the UI the app must match, and said the first build "didn't get it right". This is the checklist for closing the gap. Match **layout, hierarchy, sizes and wording**. Colours come from the app's theme (Paper by default, Studio for dark), never from the pictures:

- The pictures' blue (selected tab, Start task button, toggles, timeline marker) becomes **ink**: selected segment = ink pill with paper text; primary button = black pill (`PillButtonStyle(.primary)`); toggles use `Theme.text` tint; playhead/timecode badge = ink.
- The purple effect blocks and green/purple waveforms become ink or `textMuted` on `canvas`. **No green, ever.** Orange (`Theme.tally`) only while recording is live.
- Dashed = proposed (the "Apply 7 changes" summary card, proposed cut regions on the timeline, suggested clips not yet exported). Solid = accepted.
- The thread's assistant text in the pictures is a serif; use the theme's display/body styles as they are. Don't add new fonts.

## 1. Window chrome (all pages)

Pictures: there is **no global top bar** and no breadcrumb. The sidebar runs the full window height, starting under the traffic lights.

- Remove `HarnessView.topBar` as a full-width bar. Move its pieces into each page's own header (below).
- Use a hidden title bar / full-size content view so the sidebar reaches the top; traffic lights sit over the sidebar.
- Keep keyboard shortcuts (sidebar ⌘⌥S etc.) working through menus even though the buttons move.

## 2. Sidebar (01, 02, 03, 07; icon rail in 05)

- Top: ring logo + "Vision One" (headline).
- Then "New task" (02 shows it selected, with a filled soft background) and "Library". 01/03/07 label the first row "New recording"; use **"New task"** everywhere (it's the same page) so it's consistent.
- "PROJECTS" label, then each project as a disclosure (folder icon + name), tasks beneath with a hollow circle, title, and a muted second line "Today at 4:48 PM · 1:56" (date · take length). The selected task gets a white card background with a ring-coloured filled circle.
- "Settings" with gear pinned to the bottom.
- In Edit and Sound (05/06) the sidebar collapses to a **56px icon rail**: logo, New task, Library, current project (selected), Sound, and Settings at the bottom. 06 shows the full sidebar in Sound; prefer the rail in Edit and the full sidebar in Sound, as pictured.

## 3. Task page (01 light, 04 dark)

Three columns: sidebar | thread (about 520px) | review (the rest).

Thread column, top to bottom:
1. Header: task title (large, bold), muted "Project · Saved on this Mac" under it; on the right a secondary "Export" pill with share icon and a "…" menu (this menu holds what `contextualTools` held). Hairline under the header.
2. The conversation: user ask with avatar initials; assistant reply with the ring logo.
3. The proposals as **one grouped card** of rows (icon, title, one-line description, count like "4 cuts", chevron). Rows: Trim pauses, Remove filler words, Add captions, etc., built from the task's real plan/approvals.
4. A **dashed** summary card: "2:14 → 1:56" big, "7 changes · 18 seconds saved" muted, then a full-width black "Apply 7 changes" and a full-width outline "Review individually".
5. A "✓ 3 completed steps" disclosure row (replaces "N completed updates").
6. Composer pinned at the bottom: rounded field "Ask for a change, or describe what to do…", send button, and the "On this Mac" picker beneath.

Review column (replaces the tab strip of components):
1. The video player on top, large, with its own transport row: play, "0:24 / 2:14", scrubber, volume, speed "1×", fit, fullscreen.
2. Below it, two tabs as a segmented control: **Transcript** | **Changes (7)**, with search and filter icons at the right.
3. Transcript rows: monospaced timestamp at left ("00:24"), paragraph text at right; the current paragraph is highlighted with a soft fill and its timestamp gets a dashed outline.
4. The old panel tabs (Clips, Sound, Thumbnail, etc.) move: Clips/Thumbnail/Post become the Delivery view (07), Sound is its own mode (06). Keep "Show below"/split and full-window as options in the "…" menu if needed, but the default must look like 01.

## 4. New task (02)

- Sidebar | centre | right rail "Project defaults" (about 340px).
- Centre, left-aligned (not centred): "What are we making?" display, muted subtitle "Start a new task with a recording, a video, a script, or Autopilot."
- **Four equal cards in one row**: Record a walkthrough (ring icon, selected style), Import a video, Write a script, Run an Autopilot demo. Icon, bold title, two-line muted detail.
- The composer as a **large card** (multi-line, about 130px tall) with attach and mic buttons bottom-left, "On this Mac" picker, and a black "Start task →" pill bottom-right.
- Drop the dashed starter chips from this page (they're not in the picture).
- Right rail: "Project defaults" title with a grid icon; a grouped card with rows House style (Paper), Captions (English), Format (Original), each icon + label + value + chevron menu. Then "Recent video": thumbnail with duration badge, title, "Oct 29, 2026 · 1440 × 1024", "…" button. Then "Script sources": "Add a script or notes" row.

## 5. Ready to record (03)

Shown as the **review column** of the task page (not a sheet) when you start a recording from a task or from New task:
- Thread column: the assistant says it's setting up; a grouped card of rows (Capture window · Acme app selected, Microphone, Camera, Use script · 2 lines · Teleprompter on), then a dashed "Recording will create" card with black "Start recording" and outline "3 second countdown".
- Review column: "Ready to record" title + subtitle, Screen | Window | Area segmented control, live source preview, then rows: Microphone with level meter, System audio toggle, Camera with small preview + toggle, Script (teleprompter) disclosure showing the script with "Edit script", then full-width black "● Start recording" and outline "⏱ 3 second countdown".
- **Only one** of the two Start recording buttons may be enabled at a time: keep the one in the review column; the thread card shows the summary and a "Start recording" that scrolls/focuses the same action, or drop the thread copy. The plan says: one obvious Record action.

## 6. Editor (05)

- Icon rail sidebar.
- Header: title with chevron menu, muted "Project · Saved on this Mac · date"; centred segmented **Task | Edit | Sound**; right: undo, redo, version picker ("Main cut"), Export pill, "…".
- Tool row: Select, Cut, Zoom, Blur, Draw as labelled tool buttons (selected = outlined), zoom % menu, fit and fullscreen icons.
- Preview with captions overlaid; transport under it.
- Right: Transcript | Changes (3) tabs, transcript with timestamps; selecting words shows a floating "✂ Cut words ▾" button.
- Full-width timeline below both: time ruler with ink playhead badge, tracks labelled Video (thumbnails), Audio (waveform), Effects (blocks for Captions, Blur, Draw). Proposed cuts are dashed hatched regions.
- Bottom: ask bar "Ask for an edit, or hold Space to talk…" with sparkle icon and send.

## 7. Sound (06)

- Header like the editor, with the segmented control; Export and "…".
- Preview at left; right card "Keep your voice clear" + subtitle; Voice energy segmented (Calm | Lively | Viral); Music picker with artwork; Music volume slider with %; "Lower music while speaking" toggle; "Sound effects" row with chevron.
- Tracks below: Voice, System audio, Music, Effects, each with icon, mute button and volume slider at left and its waveform at right; time ruler and playhead.
- Bottom: composer "Make the music softer when I'm talking…" and a large "Apply mix" pill on the right.

## 8. Delivery (07)

- Task page layout. Thread column: the ask and reply, then "Suggested clips" card (count at right) with clip rows: thumbnail with duration badge, "00:24 → 00:54" monospaced, bold title, two-line description, chevron; selected row outlined. Then "Post copy" card: Title field, Copy text area with "91/280" counter, "Copy text" button.
- Review column: segmented **Clips | Thumbnail | Post**; large vertical preview with captions and the camera bubble; transport; format choice Original | Vertical | Square as three outlined buttons (selected = ink outline); an export card: resolution menu (1080p), Captions toggle, "Estimated size 52 MB", black "Export clip"; "More export options" disclosure with WhatsApp (optimized), Subtitle files (SRT, VTT), Languages & versions.

## Done means

- `--verify-workspace` renders of task, new-task, recording, editor, sound and delivery (light and dark, wide) put side by side with 01-07 look like the same app: same columns, same order, same controls, same wording.
- Narrow and minimum sizes still work (no clipped controls); every existing feature is still reachable (via "…" menus if not pictured).
- `swift test` and the Debug build pass.

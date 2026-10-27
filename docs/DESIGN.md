---
# gstack: design-md-format=spec
name: Vision One
description: Quiet ink-on-paper recorder that stays out of the way, with one orange tally light and the builder's ring as the status light.
colors:
  paper: "#FFFFFF"
  canvas: "#F4F4F1"
  line: "#E2E1DC"
  line-strong: "#8A8984"  # control edges (fields, switches off); 3.5:1, meets WCAG 1.4.11
  text: "#121212"
  text-muted: "#5C5B57"
  text-faint: "#767570"  # placeholders, tertiary text; 4.6:1
  primary: "#121212"
  on-primary: "#FFFFFF"
  tally: "#FF5A1F"
  tally-soft: "#FFE3D6"
  filler-bg: "#FBEFD3"
  filler-text: "#7A4E05"
  cut-text: "#A9A8A3"
  selection: "#1F3FBF"
  selection-soft: "#E4E8FA"
  error: "#B3261E"
  error-soft: "#F9E1DE"
  ring-red: "#D62B2B"
  ring-blue: "#1F3FBF"
  ring-gold: "#E0A21B"
  ring-green: "#1E7D4F"  # Version One identity only; not offered as an app accent
  accent-purple: "#7A3FBF"
  accent-pink: "#C2306E"
  paper-warm: "#FFFDF8"
  canvas-warm: "#F5F0E6"
  paper-cool: "#FBFBFD"
  canvas-cool: "#EEF0F4"
  ring-black: "#121212"
typography:
  display:
    fontFamily: Bricolage Grotesque
    fontWeight: 300 and 800
    fontSize: clamp(1.6rem, 4vw, 3.2rem)
    letterSpacing: -0.025em
  body:
    fontFamily: Bricolage Grotesque
    fontVariation: opsz 12
    fontSize: 13px
    lineHeight: 1.4
  transcript:
    fontFamily: Source Serif 4
    fontSize: 16-18px
    lineHeight: 1.8
  label:
    fontFamily: Bricolage Grotesque
    fontVariation: opsz 12
    fontSize: 11px
    letterSpacing: 0.06em
  mono:
    fontFamily: JetBrains Mono
    fontFeature: tnum
rounded:
  sm: 4px
  md: 8px
  lg: 12px
  full: 9999px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  2xl: 48px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.full}"
  button-secondary:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.text}"
    borderColor: "{colors.text}"
    rounded: "{rounded.full}"
  record-button:
    backgroundColor: "{colors.paper}"
    dotColor: "{colors.tally}"
    rounded: "{rounded.full}"
  input:
    borderColor: "{colors.line-strong}"
    rounded: "{rounded.sm}"
  panel:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.lg}"
---

# Vision One

Preview page: https://claude.ai/artifact/8yebDKZHmVUwZ8ukpAof5N (source vision-one-design.html).

## Overview

**Creative North Star:** Version One's black-and-white page, made quiet enough to sit next to someone's work while they record, with one light that says "you're live".
**Product context:** free open source native macOS screen recorder with a transcript-first AI editor, for South African builders; sibling to the Version One directory.
**Mode per surface:** Operate (recorder bar, editor controls, export), Read (transcript), Persuade (website, later), Experience (none).
**Reference sites:** none opened; built from design knowledge plus Version One's R3 Faces rules. Loom and Riverside informed features, not looks.
**Key characteristics:** white panels on a warm-grey canvas; black pill buttons; a single round record button; the builder's ring on the camera bubble and on every take; the transcript reads like writing.

## Colors

**Strategy:** Restrained. Ink and paper do almost everything. Tally orange (Version One's hot orange) has one job: recording is on. Builder ring colours are identity, never UI state.
**Light or dark:** light only. Lee's standing rule, and the use scene (builders demoing light web apps in daytime) agrees. No dark mode.
Selection blue marks selected words and focus. Error red is darker than tally so they never read as the same thing. There is no success green: a finished export is shown by the ring turning solid in the builder's own colour.

## Typography

Three families (v2 dropped Instrument Sans), each with one job, all on Google Fonts under the SIL Open Font Licence (verified 27 Oct 2026; css2 API returned 200 for each), so they can be bundled in the app.
- Bricolage Grotesque: display at large optical size, 300/800 (empty states, export done, onboarding); controls and labels at opsz 12, 400-600, 11-13px, so one family runs the whole app. Kept from Version One.
- Source Serif 4: the transcript. Deliberate risk: editing the video should feel like editing writing.
- JetBrains Mono with tabular digits: timecodes, sizes, durations, so numbers never jump while recording.
Native macOS menus, alerts and Settings stay in the system font.

## Layout

Editor window: 200px takes sidebar, stage (preview, timeline, transport), transcript pane. 44px toolbar. 4px base grid, compact Mac density. Below 1000px the sidebar hides; below 640px panes stack.

## Elevation & Depth

Panels sit on the canvas with a 1px line. Floating things (recorder bar, sheets) get one offset soft shadow. No glows, no frosted glass.

## Shapes

Pills for buttons, one circle for record, 8px for fields and alerts, 12px for panels and sheets. No card inside a card.

## Components

- **Grammar (v2):** dashed = proposed by the AI or not yet done; solid = accepted or done; orange = live. Applies to rings, AI changes, format shapes and takes.
- Home launcher: "What are you making?" template cards beside the record pane.
- Changes list: each AI change is a row with a switch; dashed until accepted; "Accept all" turns rows solid. Sits in a Changes / Transcript tab pair.
- Ask bar: one text field at the foot of the editor plus a pen button for drawing feedback on a frame.
- Format shapes: export formats drawn at their true ratio; suggested ones dashed.
- Prompt any part: timeline parts (Hook, Title, Body, Outro) as a segmented strip and whole-video parts (Captions, Zooms, B-roll, Music, Thumbnail, Title + post, House style) as pills. Selecting one opens a prompt sheet: textarea dashed while it holds the template default, solid once edited; variable chips ({product}, {audience}, {site}, {cta}, {ring}); model pill; "Save as preset" and "Redo this part". Edited parts get an ink underline.
- Power in three depths (from DaVinci Resolve): 1 Auto (tool runs, shows as a dashed row in Changes); 2 Amount (an opened change shows one slider or one prompt, never a panel); 3 Open in DaVinci Resolve (handoff card: FCPXML/OTIO, split tracks, SRT, markers).
- Energy dial: three-way segmented control (Calm, Lively, Viral) that sets zooms, sound effects and caption style together; templates set the starting value.
- Appearance (Make it yours): user can set accent (blue, red, gold, purple, pink, black; no green), paper tone (white, warm, cool; always light), transcript font (Source Serif 4, Bricolage, Atkinson Hyperlegible "Easy read"), text size S/M/L, layout (video left, text left, no timeline), density (roomy 16px, compact 12px), camera bubble (circle, rounded square). Saved as theme.json. Fixed and not themeable: tally orange for recording, light mode, ink buttons, error red.
- Caption styles: four presets; keyword captions use the builder's ring colour, never orange.
- Record button: white circle, ink border, orange dot; while live the border turns orange and the dot becomes an ink stop square.
- Recorder bar (HUD): white pill, blinking orange REC dot, mono timecode, pause, draw, stop. Never captured in the recording.
- Ring states: dashed = draft; dashed and slowly turning with an orange centre = recording; filling arc = exporting; solid with version label = exported.
- Transcript words: filler = gold tint with dark gold text; cut = grey with a line through, still visible; selected = blue tint with underline; playing = ink underline; pauses = mono duration chip with dashed border.
- Timeline: speech in ink, fillers in ring gold, pauses hatched grey, cuts hatched and faded; ink playhead.
- Alerts: tint plus bold lead sentence; errors say how to fix (for example the Screen Recording permission path).
- Every component has empty, loading, error and long-content states before it ships.

## In code

Design system page: https://claude.ai/artifact/NnmfdaiRzynzza5MayyV2M (tokens, type, every component with its states, the app icon options and the shortcut map).

- **Values:** `Sources/VisionOneKit/Design/DesignTokens.swift` holds every colour as hex; `swift test` checks text pairs reach 4.5:1 and control edges and the focus ring 3:1. `App/Sources/Theme.swift` turns them into SwiftUI colours, plus `Space`, `Radius`, `Size`, `Stroke` and `Motion`. Never write a hex value or a `.font(.system(...))` in a view.
- **Type:** `Text("Export").textStyle(.headline)`. Styles: `display`, `displayLight`, `title`, `headline`, `body`, `bodyStrong`, `label`, `caption`, `mono`, `monoSmall`, `transcript`. Fonts are bundled in `App/Resources/Fonts` (static OFL instances) and registered at launch. View → Bigger Text / Smaller Text (⌘+ / ⌘-) scales every style.
- **Components** (`App/Sources/DesignSystem/`): `PillButtonStyle` (`.primary`, `.secondary`, `.quiet`, `.destructive`; small, regular, large), `IconButton`, `SegmentedTabs`, `.toggleStyle(.ink)`, `.textFieldStyle(.ink)`, `ListRow`, `.panelStyle()`, `CollapsibleSection`, `SheetScaffold`, `EmptyState`, `Notice`, `Tag`, `StateChip`, `.statusOutline(_:)`, `Mono`, `LiveDot`, `BuilderRing`.
- **Ease first:** one primary (black) button per view, a sensible default already chosen, Return confirms and Esc cancels every sheet, and no empty screen without its next step.
- **Accessibility:** every icon-only control has a VoiceOver label and a tooltip (`IconButton` makes both from one title); custom controls draw a 2px selection-blue focus ring; Increase Contrast turns muted text to ink and lines to `line-strong`; Reduce Motion stops the ring turning and the REC dot blinking; hit targets are at least 24pt.
- **Shortcuts:** `Sources/VisionOneKit/Design/ShortcutMap.swift` is the one list. Bind with `.keyboardShortcut(ShortcutMap.export)` and name it in tooltips with `.help("Export", shortcut: ShortcutMap.export)`. A test fails on two shortcuts sharing keys or on taking a standard macOS shortcut. Help → Keyboard Shortcuts (⌘/) lists them all.
- **App icon:** `App/Resources/Assets.xcassets/AppIcon.appiconset`, from `docs/icon/b-record-dot.svg`: the builder's ring, dashed turning solid, around the record button's orange dot.

## Do's and Don'ts

- Do: use orange only while recording; show status with the ring's shape; set every number in tabular mono; keep cut words visible; hide Vision One windows from captures.
- Don't: add dark mode or a green success colour; use orange for buttons, links or badges; nest cards or add glows; set the transcript in a sans; animate anything except the ring and the tally light.

## Motion

- **Approach:** minimal-functional.
- **Easing:** enter(ease-out) exit(ease-in) move(ease-in-out)
- **Duration:** micro(50-100ms) short(150-250ms) medium(250-400ms) long(400-700ms)
- **The one authored moment:** on export, the dashed ring fills and closes solid (about 600ms), with the version label appearing after.
- Countdown before recording is drawn as the ring losing three segments. Reduced motion: no spin, no blink.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-10-27 | Initial design system created | /design-consultation from Version One R3 Faces plus recorder needs; no outside voices, no competitor screenshots |
| 2026-10-27 | Tally orange reserved for recording | One unmistakable "live" signal; reuses Version One hot orange |
| 2026-10-27 | Transcript in Source Serif 4 | Editing by text should feel like editing writing |
| 2026-10-27 | Ring shape as status, no success green | Matches Version One dashed/solid rule; respects no-green rule |
| 2026-10-27 | Style v2: dashed = proposed, solid = done, orange = live | One grammar for rings, AI changes, formats and takes |
| 2026-10-27 | Dropped Instrument Sans; Bricolage at opsz 12 for controls | Three families instead of four; one voice from display to toolbar |
| 2026-10-27 | Added launcher, changes list, ask bar, format shapes, caption styles | Covers the feature map's record, pick template, review, export flow |
| 2026-10-27 | Prompt any part of a template | Lee: prompting for parts of templates; defaults stay dashed so nobody has to type, edits go solid |
| 2026-10-27 | Power in three depths + Open in Resolve | Lee: learn from DaVinci Resolve Studio but stay simple; Resolve is the next step, not the rival |
| 2026-10-27 | Sound effects and punch-in zooms via an Energy dial | Lee asked about SFX and zooms; one control keeps them tasteful and under the voice |
| 2026-10-27 | Design system in code: tokens in VisionOneKit, components in App/Sources/DesignSystem | One place for every value; contrast and shortcut clashes tested by `swift test` |
| 2026-10-27 | Added line-strong and text-faint | `line` (1.3:1) and the old input border (1.7:1) are too faint to mark a control; WCAG 1.4.11 asks 3:1 |
| 2026-10-27 | Bundled static font instances | Bricolage's variable default is 96pt ExtraBold; static opsz 12 text and opsz 96 display instances are predictable |
| 2026-10-27 | App icon: ring around the record dot (option B; A and C in docs/icon) | The app had none; the icon is the record button itself, so its orange dot keeps meaning "record" |
| 2026-10-27 | User appearance settings (theme.json) | Lee: customise the app's own look; orange and light-only stay fixed so status and the no-dark rule hold |

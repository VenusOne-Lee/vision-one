# Autopilot and self-updating demos

Autopilot clicks through your app while Vision One records, following saved steps. When you ship a release, it records the demo again with the new UI, so your demo videos never go stale.

Visual page (mockups, how it works, research): https://claude.ai/artifact/SxL2e8Sdub37xkKWs8EUsU

## Using it

1. **Autopilot…** (File menu) opens the Autopilot window.
2. **New Demo**, pick the app, and either press **Record Steps** and click through your app once, or type the steps as plain lines.
3. **Run Autopilot**. A 3-second countdown, then Vision One records the app's window while Autopilot does each step. The take opens in the editor when it's done.
4. To keep it fresh, type your repo (`owner/repo`) and turn on **Re-record when I ship a release**.

Autopilot records the window without your mic. Read the script over the take afterwards; each step's `Say` line is the script for that step.

## Steps in plain words

One step per line. `#` starts a comment. A `Say` line is the script for the step above it.

```
Open https://rankride.co.za/ranks
Click the "Bree St rank" link
Say "Pick your rank, and you're in."
Point at "Queue count"
Type "Thabo" into "Name"
Press cmd+return
Scroll down 5
Wait 1.5s
Wait for "Receipt"
Click #pay-button
```

| Step | Does |
| --- | --- |
| `Open <address>` | Opens a web address or file in the demo's app |
| `Click "<name>"` | Glides to it and clicks. Add the kind to be exact: `the "Pay" button`, `the "Docs" link`. `#id` uses the app's accessibility identifier |
| `Point at "<name>"` | Glides there and rests, so viewers look at it |
| `Type "<text>" into "<name>"` | Clicks the field and types. Without `into`, types into what has focus |
| `Press <keys>` | `cmd+k`, `shift+cmd+p`, `return`, `esc`, `f5` |
| `Scroll <up/down/left/right> [lines] [over "<name>"]` | Scrolls, 5 lines by default |
| `Wait <time>` / `Wait for "<name>"` | Waits, or waits until something appears |

`StepWords` (VisionOneKit) reads and writes these lines.

## How it finds things

Autopilot reads the app's accessibility tree (`AXReader`, the same tree VoiceOver uses) and matches each step's target by identifier, then role and visible name (`TargetMatcher`), the way Playwright's `getByRole` does. Positions don't matter, so a re-record survives a layout change. It waits up to 8 seconds for a target to appear.

When a target is gone (the button was renamed), the step fails and `TargetMatcher.suggestion` offers the likeliest replacement: the same kind of thing near where the old one was, or with a close name. It shows dashed in the Autopilot window with **Use It**; nothing is changed until you keep it. A recorded click on something with no name at all falls back to its spot in the window, and the step is marked as using a position.

For Chrome, Dia, Arc and Electron apps Autopilot turns on their web accessibility tree (`AXManualAccessibility`). Menu bar menus aren't read yet; use `Press` with the shortcut.

## Safety

- **Only the demo's apps.** `appsInPlay` is the demo's app plus `allowedApps`. Before every click Autopilot checks what is really under the cursor and what is in front for typing.
- **Never:** System Settings, Terminal, iTerm, Warp, Ghostty, Keychain Access, Passwords, 1Password, Bitwarden, Script Editor, Automator, Installer, or Vision One itself (`AutopilotPolicy.alwaysBlocked`). A demo can't allow them.
- **Never password fields.** It won't click or type into a secure field, and Record Steps never records what you type into one.
- **Visible.** The pill at the top of the screen says "Autopilot is driving Safari · step 3 of 8" the whole run, and is kept out of the recording.
- **Esc stops it.** Moving the mouse, clicking, scrolling or typing pauses it ("You took over") until you press Resume. Its own events carry a tag (`InputPoster.tag`) so it never pauses itself.
- **Asks first when you're not there.** A run started by a release, the GitHub Action or the MCP server asks "Let Autopilot record …?" unless you already said these exact steps may run on their own. Turning on **Re-record when I ship a release** is that yes; so is "Record, and don't ask again". Change the steps or apps and it asks again (`DemoFingerprint`).
- **Stops by itself** after 10 minutes.

Autopilot needs Accessibility access (System Settings → Privacy & Security → Accessibility). It asks the first time.

## The demo file

Demos are JSON files in `~/Library/Application Support/Vision One/Demos/`, or in your app's repo at `.visionone/demos/*.json` after **Link a Repo…**, so they change with your code and go through review.

```json
{
  "version": 1,
  "name": "Checkout demo",
  "app": { "bundleID": "com.apple.Safari", "open": "https://rankride.co.za/ranks" },
  "allowedApps": [],
  "window": { "width": 1440, "height": 900 },
  "pace": "normal",
  "repo": "VenusOne-Lee/rankride",
  "rerecordOnRelease": true,
  "steps": [
    { "do": "click", "target": { "role": "AXLink", "name": "Bree St rank" }, "say": "Pick your rank." },
    { "do": "point", "target": { "name": "Queue count" } },
    { "do": "type", "target": { "name": "Name" }, "text": "Thabo" },
    { "do": "press", "keys": "cmd+return" },
    { "do": "wait", "seconds": 1.5 }
  ]
}
```

`window` resizes the app's window before recording. `pace` is `calm`, `normal` or `quick` (cursor speed, typing speed and the pause after each step). A target can also have `identifier`, `index` (which of several with the same name, in reading order) and `lastSeen` (where it was, as fractions of the window).

## What a run leaves

- A take like any other, recorded from the app's window, opened in the editor.
- `autopilot.json` in the take (`AutopilotRun`): each step with its start and end time on the video, whether it used a position, a suggested fix if it broke, the release, who asked, and the script.
- A task on the Agent Desk (agent `autopilot`): "Re-record “Checkout demo” for v1.4.0", one step per line. A release run that finishes waits under Needs you; one with a suggested fix waits there too.
- `~/Library/Application Support/Vision One/Autopilot/state.json`: per demo, the last release recorded, the last take, and the steps you approved for running alone.

## Releases

GitHub's own Mac runners can't grant Screen Recording, so the recording always happens on your Mac. Two ways to get there:

**Vision One watches (default).** For each demo with a `repo` and `rerecordOnRelease`, Vision One asks GitHub for the latest release when it opens and every hour (`ReleaseWatcher`, public repos need no sign-in). The first release it sees is the starting point; the next published, non-draft, non-prerelease one re-records the demo. A run that fails isn't retried until Vision One restarts.

**GitHub Action on a self-hosted Mac runner.** Install a [self-hosted runner](https://docs.github.com/actions/hosting-your-own-runners) on the Mac with Vision One, then:

```yaml
on:
  release:
    types: [published]
jobs:
  demos:
    runs-on: [self-hosted, macOS]
    steps:
      - uses: VenusOne-Lee/vision-one/.github/actions/rerecord-demos@main
        with:
          demos: |
            Checkout demo
            Driver sign-up
```

The action opens `visionone://demo/rerecord?name=…&release=…&request=<id>` for each demo and waits for `Autopilot/requests/<id>.json` (`RerecordStatus`) to say `recorded` or `stopped`. The step fails if any demo doesn't finish. Anything else on the Mac can use the same link.

**MCP.** The Vision One MCP server calls `AutopilotService.shared.rerecord(name:release:requestedBy:)`, which returns the Agent Desk job id; progress shows on the job board like any agent task.

## Code

| Where | What |
| --- | --- |
| `Sources/VisionOneKit/Autopilot/DemoScript.swift` | The demo file, steps, targets, pace |
| `Sources/VisionOneKit/Autopilot/StepWords.swift` | Plain-words steps and key combos |
| `Sources/VisionOneKit/Autopilot/AutopilotPolicy.swift` | What Autopilot may do, stop reasons, `UICandidate` |
| `Sources/VisionOneKit/Autopilot/TargetMatcher.swift` | Finding a target, suggesting a fix, naming a recorded click |
| `Sources/VisionOneKit/Autopilot/CursorPath.swift` | The eased cursor glide |
| `Sources/VisionOneKit/Autopilot/AutopilotRun.swift` | autopilot.json, receipts, `DemoFingerprint` |
| `Sources/VisionOneKit/Autopilot/DemoLibrary.swift` | Demo folders and state.json |
| `Sources/VisionOneKit/Autopilot/ReleaseWatch.swift` | Releases, the rerecord link, request status files |
| `App/Sources/Autopilot/` | Accessibility reader, input, guard, pill, the run service, Record Steps, the release watcher and the window |
| `.github/actions/rerecord-demos/` | The composite Action |

## Not yet

- Reusing last take's voice: the run notes whether the script is unchanged (`voiceFits`), but lining an old voice up with new clicks comes with the teleprompter and redo-a-sentence work.
- A browser driver (Playwright) for web demos that need more than the accessibility tree.
- Menu bar menus as targets.

## Accessibility preflight and failed starts

The Autopilot surface and Access settings show Accessibility readiness separately from screen/mic/camera access. The direct Settings action opens macOS Privacy & Security → Accessibility. Each demo publishes its own start failure and preserves the failed board job, so an unsuccessful preflight is visible without manufacturing a run/capture.

At 9e1d8ed, human-granted Accessibility enabled one actual Activity Monitor Wait-only run and resulting capture/task. At 64625f6, the updated adhoc binary was untrusted: native AX controls/text showed readiness, Run produced the named needs-Accessibility error without capture, and the direct Settings button opened the correct page. No permission toggles changed in that pass. The screenshot returned white, so that check establishes text/controls/route, not visual parity. Multi-step click/type/reconnect remains unverified. The deterministic denied-preflight native fixture passed at 5f0fbab / CI40953770394, including the retained failed board job and published visible-feedback state.

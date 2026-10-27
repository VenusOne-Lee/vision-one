# Vision One

A free, open source (MIT) native macOS screen recorder with a transcript-first AI editor, for South African builders. Sibling of Version One (versionone.co.za).

- **Stack:** SwiftUI on Apple Silicon, macOS 15+. ScreenCaptureKit + AVFoundation to record. Plain logic lives in the `VisionOneKit` Swift package (`swift test`). The Xcode project is generated with XcodeGen from `project.yml`.
- **CI:** `.github/workflows/ci.yml` runs `swift test`, then an unsigned `xcodebuild` on a macOS runner.
- **Look:** follow `docs/DESIGN.md`. Light by default: Paper is the default look; the Studio dark preset (Lee approved it 27 Oct 2026) is a choice in Settings › Appearance, and no other dark mode. No green accents or success green. Ink on paper (white panels on #F4F4F1, black pill buttons, #121212 text). Tally orange #FF5A1F means only "recording is live", never buttons, links or badges. Dashed means proposed, solid means accepted.

## gstack

[gstack](https://github.com/garrytan/gstack) skills (`/review`, `/investigate`, `/cso`, `/office-hours`, `/plan-ceo-review` and more) are installed in cloud sessions by `.claude/hooks/gstack-cloud.sh`. On a Mac, install once by hand: `git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./bin/gstack-config set telemetry off && ./setup`.

- **Native app, not a website.** Vision One is a Mac app, so gstack's browser QA (`/qa`, `/qa-only`, `/design-review`, `/browse`) has nothing to drive here. The cloud container is Linux with no Swift toolchain or Xcode, so it can't build or run the app. Build, run and QA on Lee's Mac (or through the macOS CI job). Use `/review`, `/investigate`, `/cso` and the planning skills freely in the cloud.
- **Browsers.** If a web page needs QA (a Version One page, a docs site), use gstack's `/browse` headless Chromium for localhost and preview builds, and Claude in Chrome when Lee's signed-in browser is needed. Lee's own browser is Dia. gstack's "never use Claude in Chrome" rule doesn't apply.
- **Cloud sandbox network.** versionone.co.za is blocked from the cloud container (proxy 403). QA the live site from the Mac.
- **Releases.** Vision One ships as a notarised DMG with Sparkle updates and a Homebrew cask, from the `Release` workflow (`docs/RELEASING.md`). The version is typed when the workflow runs, so don't use `/ship` VERSION and CHANGELOG bumps or `/land-and-deploy`. Publishing a release reaches every user; ask Lee before running it.
- **Design.** gstack's design skills (`/design-consultation`, `/design-shotgun`, `/design-review`, `/plan-design-review`) must keep to `docs/DESIGN.md`: no new palette outside the Appearance presets, no dark look besides Studio, no green, orange only for live recording.
- **Scope.** `/office-hours` and `/plan-ceo-review` may suggest scope. The v0.1 / v0.2 / v0.3 plan in the README and Lee's scope doc decide.
- **Team mode** is optional. Never run `gstack-team-init required`.

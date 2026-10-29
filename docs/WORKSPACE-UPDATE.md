# Workspace update — 29 October 2026

Implemented the first core workflow improvements from the Producer Workspace direction:

- Larger proportional video stage, draggable split, stacked layout for narrow content areas.
- Completed receipts, log entries and answered approvals grouped in an expandable history; pending review remains visible.
- Direct Export action and Paper/Studio appearance switch.
- Responsive composer, compact take card, clean sidebar status labels.
- Library filters using the existing tested query model.
- Exact natural-language navigation requests open their tools instead of launching an edit job.
- Social handoff labels describe copying and opening, not automatic publication.
- Clips receive caption overlays, subtitle sidecars, brand overlays and the separate camera track.

Verification: Xcode Debug build passed; 821 Swift tests passed; native UI inspected in light and dark. Export sheet opens, review filter reduces the library to matching takes, and composer wraps without overflowing. Existing SoundTests expression was simplified to resolve a compiler type-check timeout without changing its expected values.

Remaining: media-level validation of clip camera/caption output; full recording setup redesign; general video import; reusable template selection/application; expanded multi-output queue; consistent redesign of advanced tool screens. This change is a core workspace iteration, not completion of the entire concept family.

## Cloud continuation

The local iteration above is historical. Cloud work continues on the same branch and draft [PR #76](https://github.com/VenusOne-Lee/vision-one/pull/76). See [CLOUD-VERIFICATION.md](CLOUD-VERIFICATION.md) for the complete requirement matrix, current commit-specific checks and unfinished gates.

Cloud additions include general video import, recording preparation and mic lifecycle checks, task-safe request routing, reusable styles/project defaults with rollback, moving clip framing, shared camera previews, saved source-audio levels, multi-take delivery queues, subtitle warnings and a native rendered-media diagnostic. None of these replaces the required real macOS walkthrough or media inspection.

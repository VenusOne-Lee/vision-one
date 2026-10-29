# Post copy and delivery handoff

Post opens a network disclosure for manual copy even when a video has no speech. Automatic Sharer drafts need at least 40 kept transcript words. Top Draft, exported-network Draft and Write a launch use the same eligibility policy; recording/edit/export success does not depend on generating posts.

Explicit edits are saved in `post-drafts.json` inside the take, keyed by network (or `versionone` for launch copy), separately from generated `share.json`. Empty copy is a saved edit. A new generated share pack does not discard manual copy. Saving reads the current sidecar before changing one destination, preserving other network drafts. Unreadable files report a retryable error and are not silently replaced; write failure retains the current visible draft and offers Retry saving copy.

The production Post panel scopes its state and AgentsModel to the take folder. Navigating to another take creates new row owners; disclosure/approval/opened state resets. Only manual words persist across navigation/relaunch. No pending approval or already-opened status is inherited by another take.

Copy and open remains an explicit approved handoff. It copies words, shows the exported video and opens the destination composer; the person publishes there. Persisting or testing a draft never invokes that handoff.

The tracking assistant reproduced the old cross-take text leak and secondary no-speech Draft bug at 9243cea. Focused cloud source/package/mounted native regressions address both; current CI and local retest remain acceptance gates. See [CLOUD-VERIFICATION.md](CLOUD-VERIFICATION.md) and [local QA provenance](verification/local-qa.json).

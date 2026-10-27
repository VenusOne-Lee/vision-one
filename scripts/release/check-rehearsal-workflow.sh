#!/bin/bash
# Checks that the release rehearsal can't publish anything. CI runs it on
# every pull request, so a change that would let the rehearsal tag,
# release, upload or touch the Homebrew tap fails before it's merged.
#
#   scripts/release/check-rehearsal-workflow.sh [.github/workflows/release-rehearsal.yml]
set -euo pipefail

WORKFLOW=${1:-.github/workflows/release-rehearsal.yml}
[[ -f "$WORKFLOW" ]] || { echo "No $WORKFLOW" >&2; exit 1; }

problems=()
# Comments may describe what's forbidden; only check the lines that run.
body=$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$WORKFLOW")

has() { grep -Eq -- "$1" <<<"$body"; }

# Started by hand only, never by a push, pull request, schedule or another workflow.
has '^on:' || problems+=("no 'on:' block")
has '^[[:space:]]+workflow_dispatch:' || problems+=("must be started with workflow_dispatch")
for trigger in push pull_request pull_request_target schedule workflow_run workflow_call release repository_dispatch; do
  has "^[[:space:]]+${trigger}:" && problems+=("must not run on '$trigger'")
done

# The job token can read and nothing else.
has '^permissions:' || problems+=("needs a top-level permissions block")
has '^[[:space:]]+contents:[[:space:]]*read' || problems+=("needs 'contents: read'")
has ':[[:space:]]*write' && problems+=("no permission may be 'write'")
has 'write-all' && problems+=("no 'write-all'")
has '^[[:space:]]+permissions:' && problems+=("no job-level permissions (they could widen the token)")
has 'persist-credentials:[[:space:]]*false' || problems+=("checkout needs 'persist-credentials: false'")

# Nothing that publishes or uploads.
forbidden=(
  'gh[[:space:]]+release' 'gh[[:space:]]+api' 'git[[:space:]]+push' 'git[[:space:]]+tag'
  'upload-artifact' 'upload-pages-artifact' 'action-gh-release' 'create-release'
  'HOMEBREW_TAP_TOKEN' 'TAP_TOKEN' 'update-cask' 'make-appcast' 'appcast\.xml'
  'secrets\.GITHUB_TOKEN' 'github\.token'
)
for pattern in "${forbidden[@]}"; do
  has "$pattern" && problems+=("must not use '$pattern'")
done

if (( ${#problems[@]} )); then
  echo "$WORKFLOW could publish or leak something:" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "$WORKFLOW can't publish: manual start only, read-only token, no uploads, no tap."

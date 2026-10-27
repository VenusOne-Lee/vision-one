#!/usr/bin/env bash
# Installs gstack (https://github.com/garrytan/gstack) in Claude Code cloud
# sessions, so /review, /investigate, /cso and the rest are there in every thread.
# On a Mac, install it once by hand instead (see CLAUDE.md).
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

GS="$HOME/.claude/skills/gstack"
if [ ! -x "$GS/browse/dist/browse" ]; then
  rm -rf "$GS"
  git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git "$GS" >/dev/null 2>&1 \
    && (cd "$GS" && ./setup </dev/null >/dev/null 2>&1) \
    || echo "gstack install failed; carry on without it." >&2
  "$GS/bin/gstack-config" set telemetry off >/dev/null 2>&1 || true
fi

# Cloud containers ship Chromium, but gstack's own download is blocked, so point it there.
CHROME=""
for c in /opt/pw-browsers/chromium /opt/pw-browsers/chromium-*/chrome-linux*/chrome; do
  [ -x "$c" ] && { CHROME="$c"; break; }
done
if [ -n "$CHROME" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export GSTACK_CHROMIUM_PATH=$CHROME" >> "$CLAUDE_ENV_FILE"
fi
exit 0

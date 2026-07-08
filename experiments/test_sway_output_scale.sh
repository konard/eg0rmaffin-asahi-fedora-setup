#!/usr/bin/env bash
# Guards the per-output scaling fix in sway/config.
#
# `output * scale 2` scales EVERY output, so an external 1080p/1440p monitor
# becomes comically huge. Only the built-in Retina panel (eDP-1 on Apple
# Silicon) should be scaled; external monitors default to scale 1.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_DIR/sway/config"

# Only look at active (non-comment) directives.
directives() { grep -E '^[[:space:]]*output[[:space:]]' "$CONFIG" | grep -vE '^[[:space:]]*#'; }

echo "== sway/config must not scale all outputs =="
if directives | grep -qE '^\s*output\s+\*\s+scale'; then
    echo "FAIL: 'output * scale' scales every monitor, not just the built-in panel"
    directives; exit 1
fi
echo "PASS: no wildcard output scaling"

echo "== built-in eDP-1 panel is scaled 2 =="
if ! directives | grep -qE '^\s*output\s+eDP-1\s+scale\s+2\b'; then
    echo "FAIL: expected 'output eDP-1 scale 2' for the built-in Retina display"
    directives; exit 1
fi
echo "PASS: only eDP-1 is scaled 2"

echo "ALL PASS: sway output scaling targets only the built-in display"

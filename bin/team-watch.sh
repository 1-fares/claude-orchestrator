#!/usr/bin/env bash
# team-watch.sh: live dashboard. Re-runs team-status.sh on an interval, ideally
# in its own tmux pane so you watch the team without tab-hopping.
#
# Usage: bin/team-watch.sh [interval-seconds]   (default 5)

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
interval="${1:-5}"

if command -v watch >/dev/null; then
  exec watch -t -n "$interval" "$repo/bin/team-status.sh"
fi

# Fallback when `watch` is unavailable.
while true; do
  clear 2>/dev/null || printf '\033[2J\033[H'
  "$repo/bin/team-status.sh"
  sleep "$interval"
done

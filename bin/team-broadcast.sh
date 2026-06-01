#!/usr/bin/env bash
# team-broadcast.sh: inject a message to every role from outside any session, by
# typing it into each role's tmux pane (tmux send-keys). This works without bus
# auth, which a standalone script cannot obtain; the orchestrator, being a
# connected session, can instead use /is b for a bus broadcast.
#
# Use it for out-of-band control. Conventions roles honor (see CLAUDE.md):
#   bin/team-broadcast.sh 'pause: stop work and wait'
#   bin/team-broadcast.sh 'resume: continue'
#   bin/team-broadcast.sh 'priority: re-read the goal in .team/state.md'
#
# Usage: bin/team-broadcast.sh '<message>'

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
active="$TEAM_DIR/active"
msg="${1:?usage: team-broadcast.sh '<message>'}"
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }
[ -f "$active" ] || { echo "no roles recorded (.team/active). Nothing to broadcast to." >&2; exit 1; }

sent=0
while IFS=$'\t' read -r pid wid role; do
  [ -n "${wid:-}" ] || continue
  if tmux_submit "$wid" "$msg"; then
    echo "-> $role"; sent=$((sent+1))
  fi
done < "$active"
echo "broadcast to $sent role(s)"

#!/usr/bin/env bash
# approve.sh: send a reply (default: 'go') into the orchestrator window of a
# specific run. Built for the phone case: one short command to advance a READY
# gate, answer a question, or inject a steering message from a small screen.
#
# Identifies the run via TEAM_RUN_ID (preferred, set by the operator) or
# --session <name>. The orchestrator's pane is always window 0, named
# 'orchestrator', in the team's tmux session.
#
# Usage:
#   TEAM_RUN_ID=<id> bin/approve.sh             # sends 'go'
#   TEAM_RUN_ID=<id> bin/approve.sh 'priority: drop unit X'
#   bin/approve.sh --session orch-12345 'pause: lunch'
#   bin/approve.sh --list                       # list candidate sessions

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

sess=""
list=0
for a in "$@"; do case "$a" in
  --session) shift; sess="${1:-}"; shift ;;
  --list) list=1; shift ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  *) break ;;
esac done

if [ "$list" = 1 ]; then
  tmux -L orchestrator list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^orch-' || echo "no live orchestrator sessions"
  exit 0
fi

[ -z "$sess" ] && sess="$TEAM_SESSION"
text="${1:-go}"

if ! tmux -L orchestrator has-session -t "$sess" 2>/dev/null; then
  echo "no such session: '$sess' on socket '$TEAM_TMUX'" >&2
  echo "candidates:" >&2
  tmux -L orchestrator list-sessions -F '  #{session_name}' 2>/dev/null | sed 's/^/  /' >&2
  echo >&2
  echo "set TEAM_RUN_ID or pass --session <name>." >&2
  exit 1
fi

# The orchestrator window is named 'orchestrator' (window 0) by start-orchestrator.sh.
target="$sess:orchestrator"
if ! tmux -L orchestrator list-windows -t "$sess" -F '#{window_name}' 2>/dev/null | grep -qx orchestrator; then
  # Fallback: window 0.
  target="$sess:0"
fi

tmux -L orchestrator send-keys -t "$target" -l "$text"
tmux -L orchestrator send-keys -t "$target" Enter
echo "sent to $target: $text"

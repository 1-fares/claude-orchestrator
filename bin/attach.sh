#!/usr/bin/env bash
# attach.sh: attach to this team's tmux session (on the dedicated team socket).
# The team runs on its own tmux socket, isolated from your default tmux server,
# so a plain `tmux attach` will not find it; use this.
#
# Usage: bin/attach.sh

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

if ! command tmux -L "$TEAM_TMUX" has-session -t "$TEAM_SESSION" 2>/dev/null; then
  echo "no team session '$TEAM_SESSION' on socket '$TEAM_TMUX'." >&2
  echo "start one with: bin/start-orchestrator.sh --tmux goals/<name>.md" >&2
  echo "(or the orchestrator runs in your terminal and only roles are in tmux:" >&2
  echo " start with bin/start-orchestrator.sh goals/<name>.md, then bin/team-status.sh)" >&2
  exit 1
fi
exec command tmux -L "$TEAM_TMUX" attach -t "$TEAM_SESSION"

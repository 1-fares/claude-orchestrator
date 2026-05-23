#!/usr/bin/env bash
# attach.sh: attach to this team's tmux session (on the dedicated team socket).
# The team runs on its own tmux socket, isolated from your default tmux server,
# so a plain `tmux attach` will not find it; use this.
#
# Usage: bin/attach.sh

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

if ! tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  echo "no team session '$TEAM_SESSION' on socket '$TEAM_TMUX'." >&2
  echo "start one with: bin/run.sh   (or bin/start-orchestrator.sh goals/<name>.md)" >&2
  exit 1
fi
# exec the real tmux binary directly (exec cannot run the `command` builtin, and
# the tmux() wrapper is a function which exec also cannot run).
exec "$TEAM_TMUX_BIN" -L "$TEAM_TMUX" attach -t "$TEAM_SESSION"

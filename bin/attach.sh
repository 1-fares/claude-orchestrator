#!/usr/bin/env bash
# attach.sh: attach to a team's tmux session (on the dedicated team socket).
# The team runs on its own tmux socket, isolated from your default tmux server,
# so a plain `tmux attach` will not find it; use this.
#
# Usage:
#   bin/attach.sh                 # attach the current team's session, which is
#                                 # $TEAM_SESSION from team-env: per-run when
#                                 # TEAM_RUN_ID is set, else the legacy per-clone
#                                 # session.
#   bin/attach.sh <session-name>  # attach a specific session (useful with several
#                                 # parallel runs in this clone). List them with
#                                 # `tmux -L orchestrator ls`.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

session="${1:-$TEAM_SESSION}"
if ! tmux has-session -t "$session" 2>/dev/null; then
  echo "no team session '$session' on socket '$TEAM_TMUX'." >&2
  live=$("$TEAM_TMUX_BIN" -L "$TEAM_TMUX" list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^orch-' || true)
  if [ -n "$live" ]; then
    echo "Live sessions on this socket:" >&2
    printf '%s\n' "$live" | sed 's/^/  /' >&2
    echo "Attach one: bin/attach.sh <session-name>" >&2
  else
    echo "start one with: bin/run.sh   (or bin/start-orchestrator.sh goals/<name>.md)" >&2
  fi
  exit 1
fi
# exec the real tmux binary directly (exec cannot run the `command` builtin, and
# the tmux() wrapper is a function which exec also cannot run).
exec "$TEAM_TMUX_BIN" -L "$TEAM_TMUX" attach -t "$session"

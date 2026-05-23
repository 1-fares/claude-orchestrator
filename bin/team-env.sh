# team-env.sh: sourced (not executed) by the team scripts. Gives each clone its
# own isolated bus and tmux session so multiple teams (different clones) never
# collide, and isolates the team's tmux from your default tmux server. Exports:
#   TEAM_REPO     absolute path of this clone
#   TEAM_SESSION  tmux session name for this team (orch-<hash>)
#   TEAM_PORT     /is bus port for this team (9500-9899, derived from the path)
#   TEAM_TMUX     dedicated tmux socket name for the team
#   INTER_SESSION_PORT  set to TEAM_PORT so spawned claude sessions join this bus
# A pre-set INTER_SESSION_PORT is honored (manual override).
#
# Why a dedicated tmux socket: tmux-resurrect/continuum (common setups) auto-save
# and auto-restore the DEFAULT server's sessions. On the default socket they
# resurrect the team's windows as stale bash shells with old scrollback after any
# teardown, which looks like "the old run won't die". The team therefore runs on
# its own socket (-L) with NO user config (-f /dev/null), so no plugins, no
# auto-restore. Every team script that calls tmux gets the wrapper below, so all
# tmux operations target this isolated socket automatically.

TEAM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_team_hash="$(printf '%s' "$TEAM_REPO" | cksum | cut -d' ' -f1)"
TEAM_SESSION="orch-${_team_hash: -5}"
: "${INTER_SESSION_PORT:=$((9500 + _team_hash % 400))}"
TEAM_PORT="$INTER_SESSION_PORT"
TEAM_TMUX="${TEAM_TMUX:-orchestrator}"
export TEAM_REPO TEAM_SESSION TEAM_PORT INTER_SESSION_PORT TEAM_TMUX
unset _team_hash

# Route every tmux call in the sourcing script through the team's own socket with
# no config loaded. `command tmux` avoids recursing into this function. The
# -f /dev/null applies when this call starts the server; it is ignored once the
# server is running.
tmux() { command tmux -L "$TEAM_TMUX" -f /dev/null "$@"; }

# team-env.sh: sourced (not executed) by the team scripts. Gives each clone its
# own isolated bus and tmux session so multiple teams (different clones) never
# collide on the flat /is namespace or the default port. Exports:
#   TEAM_REPO     absolute path of this clone
#   TEAM_SESSION  tmux session name for this team (orch-<hash>)
#   TEAM_PORT     /is bus port for this team (9500-9899, derived from the path)
#   INTER_SESSION_PORT  set to TEAM_PORT so spawned claude sessions join this bus
# A pre-set INTER_SESSION_PORT is honored (manual override).

TEAM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_team_hash="$(printf '%s' "$TEAM_REPO" | cksum | cut -d' ' -f1)"
TEAM_SESSION="orch-${_team_hash: -5}"
: "${INTER_SESSION_PORT:=$((9500 + _team_hash % 400))}"
TEAM_PORT="$INTER_SESSION_PORT"
export TEAM_REPO TEAM_SESSION TEAM_PORT INTER_SESSION_PORT
unset _team_hash

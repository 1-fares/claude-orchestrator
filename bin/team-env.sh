# team-env.sh: sourced (not executed) by the team scripts. Gives each clone its
# own isolated bus and tmux session, isolated from your default tmux server.
# Supports two modes:
#   - **Legacy / single-team mode** (no TEAM_RUN_ID in env): this clone has one
#     team at a time, on a per-clone bus port and tmux session, with state in
#     $TEAM_REPO/.team. This is today's behavior, preserved for backward compat.
#   - **Per-run mode** (TEAM_RUN_ID set, by bin/run.sh per invocation, inherited
#     by spawned children): the team gets its own bus port, tmux session, and
#     state dir derived from (clone-path + run-id), so PARALLEL teams in the
#     same clone do not collide on names, ports, or state.
#
# Exports:
#   TEAM_REPO       absolute path of this clone
#   TEAM_RUN_ID     (optional) per-run identifier; when set, port/session/dir
#                   are derived per-run. Empty/unset = legacy mode.
#   TEAM_SESSION    tmux session name for this team (orch-<hash>)
#   TEAM_PORT       /is bus port for this team (9500-9899, derived)
#   TEAM_DIR        per-team state dir ($TEAM_REPO/.team or .team-<run-id>)
#   TEAM_TMUX       dedicated tmux socket name for the team
#   TEAM_TMUX_BIN   path to the real tmux binary
#   TEAM_TMUX_CONF  the team's tmux config file
#   INTER_SESSION_PORT  set to TEAM_PORT so spawned claude sessions join this bus
# A pre-set INTER_SESSION_PORT is honored (manual override).
#
# Why a dedicated tmux socket + own config: tmux-resurrect/continuum on the
# DEFAULT server auto-save and auto-restore sessions; on the default socket they
# resurrect the team's windows as stale shells after teardown. The team runs on
# its own socket (-L) loaded with ONLY team.tmux.conf (never ~/.tmux.conf), so no
# plugins, no auto-restore, but your prefix/mouse are carried over.

TEAM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_team_hash="$(printf '%s' "$TEAM_REPO" | cksum | cut -d' ' -f1)"

if [ -n "${TEAM_RUN_ID:-}" ]; then
  # Per-run: derive port + session + state dir from (clone-path + run-id) so
  # parallel teams in this clone do not collide.
  _run_hash="$(printf '%s\0%s' "$TEAM_REPO" "$TEAM_RUN_ID" | cksum | cut -d' ' -f1)"
  TEAM_SESSION="orch-${_run_hash: -5}"
  _port_seed=$((9500 + _run_hash % 400))
  TEAM_DIR="$TEAM_REPO/.team-$TEAM_RUN_ID"
  unset _run_hash
else
  # Legacy / single-team: today's per-clone derivation, state in .team/.
  TEAM_SESSION="orch-${_team_hash: -5}"
  _port_seed=$((9500 + _team_hash % 400))
  TEAM_DIR="$TEAM_REPO/.team"
fi
: "${INTER_SESSION_PORT:=$_port_seed}"
TEAM_PORT="$INTER_SESSION_PORT"
unset _port_seed
TEAM_TMUX="${TEAM_TMUX:-orchestrator}"
# Resolve the real tmux binary now, before the wrapper function shadows the name,
# so callers can exec it directly (exec cannot run the `command` builtin).
TEAM_TMUX_BIN="$(command -v tmux 2>/dev/null || echo tmux)"
TEAM_TMUX_CONF="$TEAM_REPO/team.tmux.conf"
unset _team_hash

# Generate the team's tmux config once, importing your prefix/mouse from
# ~/.tmux.conf but none of the plugins. Edit it freely afterwards; it is
# per-clone and gitignored.
if [ ! -f "$TEAM_TMUX_CONF" ]; then
  _pfx="$(grep -hoE '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?prefix[[:space:]]+[CMS]-[a-zA-Z]' "$HOME/.tmux.conf" 2>/dev/null | grep -oE '[CMS]-[a-zA-Z]$' | head -1)"
  _pfx="${_pfx:-C-b}"
  {
    echo "# Team tmux config. The team runs on its own tmux socket loaded with"
    echo "# ONLY this file (never ~/.tmux.conf), so tmux plugins like"
    echo "# resurrect/continuum never touch the team and cannot auto-restore stale"
    echo "# sessions. Imported your prefix/mouse; edit freely (per-clone, gitignored)."
    echo "set -g prefix $_pfx"
    [ "$_pfx" != "C-b" ] && echo "unbind C-b"
    echo "bind $_pfx send-prefix"
    echo "set -g mouse on"
  } > "$TEAM_TMUX_CONF"
  unset _pfx
fi

export TEAM_REPO TEAM_SESSION TEAM_PORT INTER_SESSION_PORT TEAM_TMUX TEAM_TMUX_BIN TEAM_TMUX_CONF TEAM_DIR
[ -n "${TEAM_RUN_ID:-}" ] && export TEAM_RUN_ID

# Route every tmux call in the sourcing script through the team's own socket and
# config. The -f applies when this call starts the server; it is ignored once the
# server is running.
tmux() { "$TEAM_TMUX_BIN" -L "$TEAM_TMUX" -f "$TEAM_TMUX_CONF" "$@"; }

# tmux_submit <target> <message>: type a literal message into a role's Claude Code
# pane and submit it. A message long enough to collapse into a [Pasted text] block
# needs TWO Enters: the first only inserts a newline inside the block, the second
# submits. A single Enter therefore leaves long broadcasts, approvals, and watchdog
# nudges sitting unsent in the input. The trailing Enter on an already-submitted
# (now empty) prompt is a harmless no-op, so this is also correct for short
# messages. Routes through the team socket via the tmux() wrapper above.
tmux_submit() {
  local target="$1" msg="$2"
  tmux send-keys -t "$target" -l "$msg" 2>/dev/null || return 1
  tmux send-keys -t "$target" Enter 2>/dev/null || true
  sleep 0.4
  tmux send-keys -t "$target" Enter 2>/dev/null || true
}

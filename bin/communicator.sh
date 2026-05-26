#!/usr/bin/env bash
# communicator.sh: launch a Claude Code session in the "communicator" role.
#
# The communicator is the team's two-way liaison to the operator (role spec at
# roles/user-communicator.md). One bus identity per team run, many possible
# front-ends; the cross-launch memory lives on disk under $TEAM_DIR/comm/.
# This launcher brings up one front-end. A second invocation against a live
# team reattaches via the tmux window (idempotent) instead of double-spawning.
#
# Default: spawns in tmux session "$TEAM_SESSION" on the team's dedicated
# socket as a new window named 'communicator'. Reattaches if the window
# already exists.
#
# --foreground: run in the operator's current terminal instead of tmux (for a
#               "talk to the communicator from this shell" flow).
#
# Env:
#   COMMUNICATOR_DISABLED=1   skip-spawn no-op (mirrors DASHBOARD_DISABLED).
#   CLAUDE_BIN=<path>         override the claude binary (default: claude on PATH).
#                             The verify harness sets this to a stub.
#
# Idempotency: a second invocation skips when the tmux window already exists
# (tmux mode) or when the operator runs --foreground from another shell while
# the tmux window is up (--foreground is a separate front-end on purpose, and
# the bus auto-suffixes the role name if a second writer connects; see u28
# multi-TUI sharing).
#
# Usage: bin/communicator.sh [--foreground] [--help]

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"   # exports TEAM_SESSION, TEAM_DIR, TEAM_PORT, INTER_SESSION_PORT

usage() {
  cat <<EOF
Usage: $(basename "$0") [--foreground] [--help]

Launches a Claude Code session as the team's user-communicator role.

Default: spawns a tmux window 'communicator' in session '\$TEAM_SESSION' on the
team's dedicated socket. Reattaches if the window already exists.

  --foreground   Run in this terminal instead of tmux.
  --help, -h     Show this help.

Env:
  COMMUNICATOR_DISABLED=1   skip-spawn no-op.
  CLAUDE_BIN=<path>         override the claude binary (default: claude).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "${COMMUNICATOR_DISABLED:-0}" = "1" ]; then
  echo "communicator: skipped (COMMUNICATOR_DISABLED=1)"
  exit 0
fi

mode=tmux
[ "${1:-}" = "--foreground" ] && { mode=foreground; shift; }

[ -n "${TEAM_DIR:-}" ] || { echo "TEAM_DIR not set (source bin/team-env.sh first)" >&2; exit 2; }

# The launcher does NOT touch comm/* content; the communicator role owns those
# files. We do guarantee the directory exists at mode 0700 so the role's first
# writes never trip on a missing parent.
mkdir -p "$TEAM_DIR"
mkdir -p "$TEAM_DIR/comm"
chmod 0700 "$TEAM_DIR/comm" 2>/dev/null || true

role_file="$repo/roles/user-communicator.md"
[ -f "$role_file" ] || { echo "role file missing: $role_file" >&2; exit 2; }

claude_bin="${CLAUDE_BIN:-claude}"
command -v "$claude_bin" >/dev/null \
  || { echo "$claude_bin not on PATH (use CLAUDE_BIN to override)" >&2; exit 1; }

# Pre-trust the clone so the interactive session skips the trust prompt.
[ -x "$repo/bin/trust-workdir.sh" ] && "$repo/bin/trust-workdir.sh" "$repo" >/dev/null 2>&1 || true

# Write the launch prompt to a file; the substance lives in CLAUDE.md and the
# role file, so this prompt only needs to bootstrap (join, read, greet).
pf="$TEAM_DIR/communicator.prompt"
cat >"$pf" <<EOF
You are the user-communicator on an orchestrated Claude Code dev team.
Your bus identity is 'communicator'. The team's scripts live at \$ORCH_HOME
($repo), exported in your env. This run's shared state dir is \$TEAM_DIR
($TEAM_DIR), also exported; your conversation state lives under
\$TEAM_DIR/comm/.

Do these in order:
1. Join the bus via the /is Claude Code skill (a slash command, not a shell
   binary, do NOT use Bash for this):   /is c communicator
2. Read these files: \$ORCH_HOME/CLAUDE.md, $role_file
3. Read the five state files listed in the role file under "Conversation
   persistence across TUI sessions" BEFORE greeting the operator:
     - \$TEAM_DIR/comm/conversation.jsonl
     - \$TEAM_DIR/comm/decisions.md
     - \$TEAM_DIR/comm/open-question.json
     - \$TEAM_DIR/comm/question-queue.jsonl
     - \$TEAM_DIR/QUESTIONS-FOR-OPERATOR.md
4. Post the launch greeting as specified in the role spec
   ("communicator attached, conversation has <N> turns, <M> open questions")
   to the operator surface, and report to the orchestrator:
     /is s orchestrator 'status: communicator ready'
5. Then act on incoming bus traffic and inbound.jsonl polls per the role spec.
   Stay in the role. Send anything longer than a sentence as a file pointer.
EOF

flags="--dangerously-skip-permissions"
model_flag="--model opus"

if [ "$mode" = foreground ]; then
  export ORCH_HOME="$repo" TEAM_DIR="$TEAM_DIR"
  [ -n "${INTER_SESSION_PORT:-}" ] && export INTER_SESSION_PORT
  [ -n "${INTER_SESSION_IDLE_MINUTES:-}" ] && export INTER_SESSION_IDLE_MINUTES
  [ -n "${TEAM_RUN_ID:-}" ] && export TEAM_RUN_ID
  cd "$repo"
  echo "communicator: starting in foreground (Ctrl-C to end)."
  # exec rather than fork so the operator's shell hosts the session directly.
  # shellcheck disable=SC2086
  exec "$claude_bin" $flags $model_flag "$(cat "$pf")"
fi

# Default: tmux. Add a 'communicator' window to the team session.
command -v tmux >/dev/null || { echo "tmux not installed (use --foreground)" >&2; exit 1; }

# Reattach: if a window named 'communicator' already exists in the team
# session, skip. tmux's name-listing covers the case where the role's process
# died but the window survived (operator can re-spawn into the empty window
# manually); for an empty wedged window the operator should bin/cleanup.sh.
if tmux has-session -t "$TEAM_SESSION" 2>/dev/null \
   && tmux list-windows -t "$TEAM_SESSION" -F '#{window_name}' 2>/dev/null \
        | grep -Fxq communicator; then
  echo "communicator: tmux window already exists in session '$TEAM_SESSION'"
  exit 0
fi

# Build the launch command for the new pane. Same envelope as team-spawn.sh's
# start_one so the spawned shell sees the same environment a role would.
launch="cd $(printf %q "$repo")"
launch="$launch && export ORCH_HOME=$(printf %q "$repo") TEAM_DIR=$(printf %q "$TEAM_DIR")"
[ -n "${INTER_SESSION_PORT:-}" ] && \
  launch="$launch && export INTER_SESSION_PORT=$(printf %q "$INTER_SESSION_PORT")"
[ -n "${INTER_SESSION_IDLE_MINUTES:-}" ] && \
  launch="$launch && export INTER_SESSION_IDLE_MINUTES=$(printf %q "$INTER_SESSION_IDLE_MINUTES")"
[ -n "${TEAM_RUN_ID:-}" ] && \
  launch="$launch && export TEAM_RUN_ID=$(printf %q "$TEAM_RUN_ID")"
# shellcheck disable=SC2089
launch="$launch && exec $claude_bin $flags $model_flag \"\$(cat $(printf %q "$pf"))\""

if tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  info="$(tmux new-window -d -t "$TEAM_SESSION" -P -F '#{pane_pid} #{window_id}' \
            -n communicator "bash -lc $(printf %q "$launch")")"
else
  info="$(tmux new-session -d -s "$TEAM_SESSION" -P -F '#{pane_pid} #{window_id}' \
            -n communicator "bash -lc $(printf %q "$launch")")"
fi
pid="${info%% *}"
wid="${info##* }"
# Record in $TEAM_DIR/active so stop-team.sh / cleanup.sh / api-watchdog see it
# the same way as any other role pane.
printf '%s\t%s\tcommunicator\n' "$pid" "$wid" >> "$TEAM_DIR/active"
echo "launched communicator (pid $pid, window $wid, tmux: $TEAM_SESSION)"

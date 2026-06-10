#!/usr/bin/env bash
# start-orchestrator.sh: start the orchestrator.
#
# Default: the orchestrator and all worker roles live as windows in ONE tmux
# session on the team's dedicated socket. You attach once (bin/attach.sh) and
# switch between the orchestrator and the roles with Ctrl-b <number>. The
# dedicated socket keeps this isolated from your default tmux server and its
# plugins (resurrect/continuum), so old runs do not get auto-restored.
#
# --foreground: instead run the orchestrator in YOUR current terminal (no attach)
#               and put only the roles in tmux. Watch them with bin/team-status.sh
#               or bin/attach.sh from another terminal.
#
# Usage: bin/start-orchestrator.sh [--foreground] [goal-file]

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
# team-spawn.sh is a pure-function library (start_api_watchdog, start_tmux_watchdog,
# ...). start-orchestrator.sh is ALSO the recovery entry point: relaunch the
# orchestrator while its roles still live (after a tmux crash, or after an
# orchestrator-only restart). On that path launch-team.sh is NOT re-run, so the
# supervisor daemons it normally starts would stay dead. 2026-06-01 incident: the
# api-watchdog was down for a whole day after an orchestrator recovery, so every
# transient API rate-limit stall halted the team until a human nudged it. Ensuring
# the daemons here closes that hole; the start_* guards are idempotent (no-op if a
# live one is already recorded), so a normal cold start is unaffected.
# shellcheck source=bin/lib/team-spawn.sh
. "$repo/bin/lib/team-spawn.sh"
flags="--dangerously-skip-permissions"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 1; }

# ensure_team_daemons comes from team-spawn.sh: the one canonical daemon set,
# shared with launch-team.sh and add-role.sh so the recovery path and the
# add-role path leave the same daemons running.

# The orchestrator's model comes from the same tiered policy as every role
# (model_for in team-spawn.sh; override with TEAM_MODEL_ORCHESTRATOR or
# TEAM_MODEL_TOP). Recorded under $TEAM_DIR/models/ so the observer and the
# compaction watchdog (model-aware thresholds) read ground truth from disk.
orch_model="$(model_for orchestrator)"
orch_model_flag=""
[ -n "$orch_model" ] && orch_model_flag="--model $orch_model"

mode=tmux
[ "${1:-}" = "--foreground" ] && { mode=foreground; shift; }
goal="${1:-}"

# A previous run's roles still in tmux? Warn before starting another.
if command -v tmux >/dev/null && tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  wins="$(tmux list-windows -t "$TEAM_SESSION" -F '#{window_name}' 2>/dev/null | paste -sd, -)"
  echo "Note: a team tmux session '$TEAM_SESSION' already exists (windows: $wins)."
  echo "If that is a previous run, reset first so it does not get confusing:"
  echo "  bin/reset.sh"
  echo "Then re-run this. (Continuing would add to that session.)"
  exit 1
fi

goal_line="No goal file was given. Elicit the goal from me IN THIS SESSION as described in roles/orchestrator.md (\"get the goal in-session\"): ask for the working tree, what to build or change, constraints, mode, and team hint (use the user-questions flow plus a free-text goal), echo it back so I can confirm, then create the target if new (bin/new-project.sh) and write the brief (bin/new-goal.sh)."
if [ -n "$goal" ]; then
  if [ -f "$goal" ]; then goal_abs="$(readlink -f "$goal")"
  elif [ -f "$repo/$goal" ]; then goal_abs="$(readlink -f "$repo/$goal")"
  else echo "goal file not found: $goal" >&2; exit 1; fi
  goal_line="Read the goal at $goal_abs."
fi

mkdir -p "$TEAM_DIR"
record_role_model orchestrator "$orch_model"
# Pre-trust the clone so the orchestrator does not stop at the workspace-trust prompt.
"$repo/bin/trust-workdir.sh" "$repo" >/dev/null 2>&1 || true

pf="$TEAM_DIR/orchestrator.prompt"
cat >"$pf" <<EOF
You are the orchestrator of a Claude Code dev team. Do these in order:
1. Join the team bus using the /is Claude Code skill (a slash command, not a
   shell binary — do NOT use the Bash tool for this). Invoke it as a slash
   command response: /is c orchestrator
2. Read ./CLAUDE.md and ./roles/orchestrator.md
3. $goal_line
4. Definition of ready: do your setup first (read the goal, copy
   templates/state.md to $TEAM_DIR/state.md, break it into units), THEN present a
   single clean READY summary block exactly as specified in
   roles/orchestrator.md (goal, working tree, mode, acceptance, team, approach,
   verify) as your final message and nothing after it. Keep it short and
   scannable so I can say "go" or adjust at a glance. Then wait.
5. On "go", launch the team with bin/launch-team.sh (pass --workdir if the goal's
   working tree is outside this clone) and coordinate. Keep your context for
   orchestration: delegate code, review, and merging to the roles.
EOF

export ORCH_HOME="$repo" INTER_SESSION_PORT="$TEAM_PORT"
[ -n "${TEAM_RUN_ID:-}" ] && export TEAM_RUN_ID

if [ "$mode" = foreground ]; then
  echo "Starting orchestrator here (bus port $TEAM_PORT). It will spawn roles into"
  echo "tmux session '$TEAM_SESSION' (watch with: bin/team-status.sh). Exit with /exit."
  echo
  cd "$repo"
  # M1 (curated-role sanity): record the orchestrator's own active entry BEFORE
  # exec'ing claude, so the post-spawn sanity gates and the dashboard's roster
  # view see the orchestrator like any other role. exec replaces the shell so
  # the current pid ($$) becomes claude's pid. tmux_window column is '-' for
  # the foreground variant (no team-tmux pane).
  printf '%s\t%s\torchestrator\n' "$$" "-" >> "$TEAM_DIR/active"
  # exec replaces this shell; the nohup'd daemons survive it. Start them first.
  ensure_team_daemons
  exec ${CLAUDE_BIN:-claude} $flags $orch_model_flag "$(cat "$pf")"
fi

# Default (tmux) mode: orchestrator as window 0 of the team session; roles join
# as windows 1, 2, ... so Ctrl-b <number> switches between them in one session.
command -v tmux >/dev/null || { echo "tmux not installed (use --foreground)" >&2; exit 1; }
launch="cd $(printf %q "$repo") && export ORCH_HOME=$(printf %q "$repo") INTER_SESSION_PORT=$(printf %q "$TEAM_PORT")"
[ -n "${TEAM_RUN_ID:-}" ] && launch="$launch TEAM_RUN_ID=$(printf %q "$TEAM_RUN_ID")"
launch="$launch && exec claude $flags $orch_model_flag \"\$(cat $(printf %q "$pf"))\""
# Detach the tmux server from this shell's systemd user-session scope. May 2026
# incident: every transient `tmux-spawn-*.scope` got cleaned up simultaneously
# by the user manager, taking the whole team down. setsid puts the new tmux
# server in a new session/process group with no controlling terminal, so a
# session-cleanup event in this shell can't sweep it. systemd-run --user would
# work too but requires DBus inside WSL and is brittler.
#
# Important: setsid invokes the binary directly, so it skips the `tmux()`
# shell-function wrapper defined in team-env.sh that adds `-L $TEAM_TMUX`. We
# must pass `-L` here explicitly via the real tmux binary, or the new session
# lands on the default socket. `TEAM_TMUX_BIN` is exported by team-env.sh.
if command -v setsid >/dev/null 2>&1; then
  setsid "$TEAM_TMUX_BIN" -L "$TEAM_TMUX" new-session -d -s "$TEAM_SESSION" \
    -n orchestrator "bash -lc $(printf %q "$launch")" </dev/null >/dev/null 2>&1
else
  tmux new-session -d -s "$TEAM_SESSION" -n orchestrator "bash -lc $(printf %q "$launch")"
fi
# M1 (curated-role sanity): record the orchestrator's pane in $TEAM_DIR/active
# so the post-spawn sanity gates and the dashboard's roster view see it the
# same way as any worker role. setsid swallowed -P -F output above, so we
# query tmux directly once the session is up.
o_info="$("$TEAM_TMUX_BIN" -L "$TEAM_TMUX" display-message \
            -t "$TEAM_SESSION:orchestrator" -p '#{pane_pid} #{window_id}' 2>/dev/null \
          || true)"
if [ -n "$o_info" ]; then
  o_pid="${o_info%% *}"
  o_wid="${o_info##* }"
  printf '%s\t%s\torchestrator\n' "$o_pid" "$o_wid" >> "$TEAM_DIR/active"
fi
# Ensure the supervisor daemons are up (covers the recovery path where launch-team
# is not re-run). Idempotent.
ensure_team_daemons
echo "Orchestrator + roles will share tmux session '$TEAM_SESSION' (bus port $TEAM_PORT)."
echo "Attach now and talk to the orchestrator (Ctrl-b <number> switches to roles):"
echo "  bin/attach.sh"

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
flags="--dangerously-skip-permissions"
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 1; }

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
# Pre-trust the clone so the orchestrator does not stop at the workspace-trust prompt.
"$repo/bin/trust-workdir.sh" "$repo" >/dev/null 2>&1 || true

pf="$TEAM_DIR/orchestrator.prompt"
cat >"$pf" <<EOF
You are the orchestrator of a Claude Code dev team. Do these in order:
1. Join the team bus: /is c orchestrator
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
  exec claude $flags --model opus "$(cat "$pf")"
fi

# Default (tmux) mode: orchestrator as window 0 of the team session; roles join
# as windows 1, 2, ... so Ctrl-b <number> switches between them in one session.
command -v tmux >/dev/null || { echo "tmux not installed (use --foreground)" >&2; exit 1; }
launch="cd $(printf %q "$repo") && export ORCH_HOME=$(printf %q "$repo") INTER_SESSION_PORT=$(printf %q "$TEAM_PORT")"
[ -n "${TEAM_RUN_ID:-}" ] && launch="$launch TEAM_RUN_ID=$(printf %q "$TEAM_RUN_ID")"
launch="$launch && exec claude $flags --model opus \"\$(cat $(printf %q "$pf"))\""
tmux new-session -d -s "$TEAM_SESSION" -n orchestrator "bash -lc $(printf %q "$launch")"
echo "Orchestrator + roles will share tmux session '$TEAM_SESSION' (bus port $TEAM_PORT)."
echo "Attach now and talk to the orchestrator (Ctrl-b <number> switches to roles):"
echo "  bin/attach.sh"

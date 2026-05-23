#!/usr/bin/env bash
# start-orchestrator.sh: one-command first run. Establishes this team's tmux
# session, puts the orchestrator in window 0, joins the team bus, and seeds it
# with the definition-of-ready handshake. The orchestrator then launches the
# rest of the team with bin/launch-team.sh.
#
# Usage: bin/start-orchestrator.sh [goal-file]

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
flags="--dangerously-skip-permissions"
goal="${1:-}"
command -v tmux   >/dev/null || { echo "tmux not installed" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 1; }

if tmux has-session -t "$TEAM_SESSION" 2>/dev/null && \
   tmux list-windows -t "$TEAM_SESSION" -F '#{window_name}' | grep -qx orchestrator; then
  echo "orchestrator already running in tmux session '$TEAM_SESSION'."
  echo "Attach with:  tmux attach -t $TEAM_SESSION"
  exit 0
fi

goal_line="No goal file was given; ask me for the goal."
if [ -n "$goal" ]; then
  if [ -f "$goal" ]; then goal_abs="$(readlink -f "$goal")"
  elif [ -f "$repo/$goal" ]; then goal_abs="$(readlink -f "$repo/$goal")"
  else echo "goal file not found: $goal" >&2; exit 1; fi
  goal_line="Read the goal at $goal_abs."
fi

mkdir -p "$repo/.team"

# Pre-trust the clone so the detached orchestrator does not block, invisibly, on
# Claude Code's workspace-trust prompt before you attach.
"$repo/bin/trust-workdir.sh" "$repo" >/dev/null 2>&1 || true

pf="$repo/.team/orchestrator.prompt"
cat >"$pf" <<EOF
You are the orchestrator of a Claude Code dev team. Do these in order:
1. Join the team bus: /is c orchestrator
2. Read ./CLAUDE.md and ./roles/orchestrator.md
3. $goal_line
4. Run the definition-of-ready handshake before launching anyone: converge the
   goal into .team/state.md (copy from templates/state.md), then restate to me
   your understanding, the acceptance criteria, the team you propose, and the
   autonomy mode, and wait for my explicit "go".
5. On "go", launch the team with bin/launch-team.sh and coordinate. Keep your
   context for orchestration: delegate code, review, and merging to the roles.
EOF

launch="cd $(printf %q "$repo") && export ORCH_HOME=$(printf %q "$repo") INTER_SESSION_PORT=$(printf %q "$TEAM_PORT") && exec claude $flags --model opus \"\$(cat $(printf %q "$pf"))\""

if [ -n "${TMUX:-}" ] && [ "$(tmux display-message -p '#{session_name}')" = "$TEAM_SESSION" ]; then
  tmux new-window -n orchestrator "bash -lc $(printf %q "$launch")"
  echo "orchestrator started in window 'orchestrator' of '$TEAM_SESSION'."
else
  tmux new-session -d -s "$TEAM_SESSION" -n orchestrator "bash -lc $(printf %q "$launch")"
  echo "orchestrator started in tmux session '$TEAM_SESSION' (bus port $TEAM_PORT)."
  echo "Attach with:  tmux attach -t $TEAM_SESSION"
fi

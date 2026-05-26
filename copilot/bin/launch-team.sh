#!/usr/bin/env bash
# copilot/bin/launch-team.sh — port of bin/launch-team.sh
#
# Spawns role sessions in tmux, each joined to the /is bus.
# Driven by the orchestrator via its shell tool.
#
# Usage (same as original):
#   copilot/bin/launch-team.sh [--workdir DIR] <goal-file> <role> [<role> ...]
#
# Changes from Claude Code version:
#   - `claude` → `copilot`
#   - `--dangerously-skip-permissions` → `--allow-all`
#
# TODO(copilot-port): implement full logic from bin/launch-team.sh
# TODO(copilot-port): verify `copilot --allow-all` keeps session alive between messages
#   (claude interactive mode stays open; confirm copilot does too)
# TODO(copilot-port): confirm INTER_SESSION_PORT env var injection works with copilot
# TODO(copilot-port): adapt lib/team-spawn.sh (start_one function uses `claude`)
# TODO(copilot-port): verify api-watchdog pattern file covers copilot error strings

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
copilot_dir="$repo/copilot"

. "$copilot_dir/bin/team-env.sh"

COPILOT_BIN="${COPILOT_BIN:-copilot}"
FLAGS="--allow-all"

# Parse args (same interface as original)
workdir="$repo"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --workdir) workdir="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

goal_file="${1:?Usage: launch-team.sh [--workdir DIR] <goal-file> <role> [<role>...]}"
shift
roles=("$@")

echo "[copilot-port] launch-team.sh stub"
echo "  goal: $goal_file"
echo "  roles: ${roles[*]}"
echo "  workdir: $workdir"
echo "  COPILOT_BIN: $COPILOT_BIN $FLAGS"
echo ""
echo "TODO(copilot-port): spawn tmux windows with copilot sessions for each role"
# For each role:
#   tmux -L "$TEAM_TMUX" new-window -t "$TEAM_SESSION" -n "$role" \
#     -e "INTER_SESSION_PORT=$TEAM_PORT" \
#     -e "TEAM_DIR=$TEAM_DIR" \
#     -e "ORCH_HOME=$repo" \
#     "$COPILOT_BIN $FLAGS"
#   # then inject role instructions via tmux send-keys

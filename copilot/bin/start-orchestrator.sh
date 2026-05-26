#!/usr/bin/env bash
# copilot/bin/start-orchestrator.sh — port of bin/start-orchestrator.sh
#
# Launches the orchestrator in tmux (or foreground with --foreground).
#
# Changes from Claude Code version:
#   - `claude` → `copilot`
#   - `--dangerously-skip-permissions` → `--allow-all`
#   - Session resume flag: `--resume` (same in both CLIs, verify behavior)
#
# TODO(copilot-port): implement full logic from bin/start-orchestrator.sh
# TODO(copilot-port): verify `copilot --allow-all` suppresses all permission prompts
# TODO(copilot-port): check if copilot needs a `--system-prompt` or `--agent` flag
#   to load the orchestrator role file, or if CLAUDE.md injection is sufficient
# TODO(copilot-port): verify session ID persistence for --resume works same way

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
copilot_dir="$repo/copilot"

# shellcheck source=team-env.sh
. "$copilot_dir/bin/team-env.sh"

COPILOT_BIN="${COPILOT_BIN:-copilot}"
FLAGS="--allow-all"
ROLE_FILE="$repo/roles/orchestrator.md"

# TODO(copilot-port): implement tmux window creation + copilot launch
# Skeleton of what this should do:
#
#   tmux -L "$TEAM_TMUX" -f "$TEAM_TMUX_CONF" new-session -d \
#     -s "$TEAM_SESSION" -n orchestrator \
#     -e "INTER_SESSION_PORT=$TEAM_PORT" \
#     -e "TEAM_DIR=$TEAM_DIR" \
#     -e "ORCH_HOME=$repo" \
#     "$COPILOT_BIN $FLAGS --resume <session-id>"
#
# Then inject the orchestrator role prompt into the session.

echo "[copilot-port] start-orchestrator.sh stub"
echo "  Would launch: $COPILOT_BIN $FLAGS"
echo "  Orchestrator role: $ROLE_FILE"
echo "  tmux session: $TEAM_SESSION on socket $TEAM_TMUX"

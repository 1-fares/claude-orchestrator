#!/usr/bin/env bash
# copilot/bin/stop-team.sh — port of bin/stop-team.sh
# Gracefully ends all role sessions and the orchestrator.
#
# TODO(copilot-port): implement full logic from bin/stop-team.sh
# TODO(copilot-port): verify tmux kill-session works same with copilot sessions

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/copilot/bin/team-env.sh"

echo "[copilot-port] stop-team.sh stub"
echo "  Would kill tmux session: $TEAM_SESSION on socket $TEAM_TMUX"
# TODO(copilot-port): send graceful stop messages via team-broadcast.sh before kill
# tmux -L "$TEAM_TMUX" kill-session -t "$TEAM_SESSION" 2>/dev/null || true

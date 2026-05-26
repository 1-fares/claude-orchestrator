#!/usr/bin/env bash
# copilot/bin/run.sh — port of bin/run.sh for GitHub Copilot CLI
#
# One command to start (or attach) a run.
# Identical to bin/run.sh except:
#   - `claude` → `copilot`
#   - `--dangerously-skip-permissions` → `--allow-all`
#   - `start-orchestrator.sh` → `copilot/bin/start-orchestrator.sh`
#
# TODO(copilot-port): audit full bin/run.sh and replicate all logic below
# TODO(copilot-port): verify `copilot --resume <session-id>` works same as claude --resume
# TODO(copilot-port): check if `copilot` supports --workdir or if /cwd command is needed instead

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
copilot_dir="$repo/copilot"

: "${TEAM_RUN_ID:=r$(date +%s)$$}"
export TEAM_RUN_ID

# Source env (delegated to original — fully generic)
# shellcheck source=team-env.sh
. "$copilot_dir/bin/team-env.sh"

# TODO(copilot-port): implement recovery / attach logic from bin/run.sh
# TODO(copilot-port): implement target repo selection
# TODO(copilot-port): implement goal selection / new-goal.sh call

echo "[copilot-port] run.sh stub — not yet implemented"
echo "  TEAM_RUN_ID=$TEAM_RUN_ID"
echo "  TEAM_DIR=$TEAM_DIR"
echo "  TEAM_PORT=$TEAM_PORT"
echo ""
echo "  Launching orchestrator..."
exec "$copilot_dir/bin/start-orchestrator.sh" "$@"

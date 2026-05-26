#!/usr/bin/env bash
# copilot/bin/add-role.sh — port of bin/add-role.sh
# Adds a role to a live team.
#
# Changes from Claude Code version:
#   - `claude` → `copilot` in spawn commands
#   - `--dangerously-skip-permissions` → `--allow-all`
#
# TODO(copilot-port): implement full logic from bin/add-role.sh
# TODO(copilot-port): adapt lib/team-spawn.sh start_one() for copilot

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/copilot/bin/team-env.sh"

echo "[copilot-port] add-role.sh stub — not yet implemented"
echo "  Usage: copilot/bin/add-role.sh <role> [--workdir DIR]"
echo "  TODO: spawn new tmux window with: copilot --allow-all"

#!/usr/bin/env bash
# copilot/bin/retire-role.sh — port of bin/retire-role.sh
# Gracefully retires a single role from a live team.
#
# Changes from Claude Code version:
#   - `claude` → `copilot` in any session management commands
#
# TODO(copilot-port): implement full logic from bin/retire-role.sh
# TODO(copilot-port): confirm role graceful-shutdown protocol works same in copilot sessions

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/copilot/bin/team-env.sh"

echo "[copilot-port] retire-role.sh stub — not yet implemented"
echo "  Usage: copilot/bin/retire-role.sh <role> [--force]"

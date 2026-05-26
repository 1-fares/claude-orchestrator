#!/usr/bin/env bash
# copilot/bin/team-broadcast.sh — delegates to original (tmux send-keys, model-agnostic)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo/bin/team-broadcast.sh" "$@"

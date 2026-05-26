#!/usr/bin/env bash
# copilot/bin/team-status.sh — delegates to original (model-agnostic)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo/bin/team-status.sh" "$@"

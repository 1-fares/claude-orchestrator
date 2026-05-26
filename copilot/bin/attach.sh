#!/usr/bin/env bash
# copilot/bin/attach.sh — port of bin/attach.sh
# Attaches to the team tmux session.
# No changes needed — pure tmux, model-agnostic.
# Delegates to original.

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo/bin/attach.sh" "$@"

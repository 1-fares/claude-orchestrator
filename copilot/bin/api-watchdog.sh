#!/usr/bin/env bash
# copilot/bin/api-watchdog.sh — port of bin/api-watchdog.sh
#
# Monitors role tmux panes for retryable errors and auto-sends "try again".
# Logic is identical; only the error pattern file is different (Copilot-specific).
#
# TODO(copilot-port): verify pattern file covers all Copilot CLI transient errors
# TODO(copilot-port): confirm "try again" text works in copilot interactive mode
#   (claude accepts it; verify copilot does too)

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
copilot_dir="$repo/copilot"

# Override pattern file to use Copilot-specific patterns
export API_WATCHDOG_PATTERNS="$copilot_dir/bin/api-watchdog.patterns"

exec "$repo/bin/api-watchdog.sh" "$@"

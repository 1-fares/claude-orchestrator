#!/usr/bin/env bash
# bin/dashboard.sh — thin wrapper: source team-env.sh for $TEAM_DIR default,
# then exec the Python server. All CLI / help / exit codes live in server.py.
set -euo pipefail
ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source team-env only when the caller did not pass --team-dir, so the default
# honours $TEAM_DIR / $TEAM_RUN_ID per-run isolation. The grep is conservative
# (won't false-positive a path that happens to contain "--team-dir").
if ! printf '%s\n' "$@" | grep -qE '^--team-dir(=|$)'; then
  # shellcheck disable=SC1091
  . "$ORCH_HOME/bin/team-env.sh" 2>/dev/null || true
fi
export ORCH_HOME
exec python3 "$ORCH_HOME/bin/dashboard/server/server.py" "$@"

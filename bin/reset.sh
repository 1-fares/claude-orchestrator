#!/usr/bin/env bash
# reset.sh: end the current run for this clone and clear its run state, for a
# clean slate before starting a new one. Tears the team down (roles, orchestrator,
# and the bus, via panic.sh) and removes this run's state dir (legacy: .team/,
# per-run: .team-<run-id>/). Does NOT touch goals/ or tasks/.
#
# Scope: ONE run, the one this invocation resolves to (TEAM_RUN_ID if set, else
# the legacy per-clone team). To target a specific parallel run, pre-set
# TEAM_RUN_ID. To stop everything in this clone, run reset for each run.
#
# Use this between separate runs. For an emergency stop without clearing state,
# use bin/panic.sh. To end only the roles and keep the orchestrator, use
# bin/stop-team.sh. To recover from misfires (orphans), use bin/cleanup.sh.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

# Role tripwire: a team role session (ORCH_HOME is exported into every role by
# the spawn path) must never reset the run it belongs to — that is an operator
# action from an outside shell. RESET_CONFIRM=yes overrides for the rare
# deliberate case (e.g. the operator driving a role pane by hand).
if [ -n "${ORCH_HOME:-}" ] && [ "${RESET_CONFIRM:-}" != "yes" ]; then
  echo "reset: refusing — this shell looks like a team role session (ORCH_HOME is set)." >&2
  echo "  reset.sh destroys the live run's state dir and every role, including the caller." >&2
  echo "  Run it from an operator shell, or set RESET_CONFIRM=yes if this is deliberate." >&2
  exit 96
fi

"$repo/bin/panic.sh"
rm -rf "$TEAM_DIR"
echo "reset: team stopped, $TEAM_DIR cleared. Goals and task briefs kept."

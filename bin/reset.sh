#!/usr/bin/env bash
# reset.sh: end the current run for this clone and clear its run state, for a
# clean slate before starting a new one. Tears the team down (roles, orchestrator,
# and the bus, via panic.sh) and removes .team/ (ledger, logs, prompts, active
# record). Does NOT touch goals/ or tasks/.
#
# Use this between separate runs in the same clone. For an emergency stop without
# clearing state, use bin/panic.sh. To end only the roles and keep the
# orchestrator, use bin/stop-team.sh.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo/bin/panic.sh"
rm -rf "$repo/.team"
echo "reset: team stopped, .team cleared. Goals and task briefs kept."

#!/usr/bin/env bash
# verify-unit.sh: run a unit's verify command (build+test+lint) and gate done:.
#
# Reads the `verify:` line from tasks/<unit>.md, runs it in the CURRENT working
# tree (the role's worktree), tees output to $TEAM_DIR/verify/<unit>.log, and
# exits with the command's status. A role's `done:` is only valid with a fresh
# green log from this script; this is "done means verified" as an exit code, not
# prose. $TEAM_DIR is per-run when TEAM_RUN_ID is set, else the legacy .team/.
#
# Usage: bin/verify-unit.sh <unit>
#   run from inside the working tree you want verified.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
unit="${1:?usage: verify-unit.sh <unit>}"
# Prefer this run's per-run brief ($TEAM_DIR/tasks), fall back to the shared
# $repo/tasks (legacy single-team, or briefs the orchestrator left there). This
# keeps two concurrent runs from reading each other's identically-named brief.
brief="$TEAM_DIR/tasks/$unit.md"
[ -f "$brief" ] || brief="$repo/tasks/$unit.md"
[ -f "$brief" ] || { echo "no task brief for '$unit' (looked in $TEAM_DIR/tasks and $repo/tasks)" >&2; exit 2; }

cmd="$(grep -m1 '^verify:' "$brief" | sed 's/^verify:[[:space:]]*//')"
[ -n "$cmd" ] && [ "$cmd" != "<command that builds, tests, and lints this unit; must exit 0>" ] \
  || { echo "no usable 'verify:' command in tasks/$unit.md" >&2; exit 2; }

mkdir -p "$TEAM_DIR/verify"
log="$TEAM_DIR/verify/$unit.log"
{
  echo "# verify $unit @ $(date -Is) in $PWD"
  echo "# cmd: $cmd"
} > "$log"

set -o pipefail
bash -c "$cmd" 2>&1 | tee -a "$log"
rc=${PIPESTATUS[0]}
echo "# exit: $rc" >> "$log"

if [ "$rc" -eq 0 ]; then
  echo "verify OK ($unit) -> $log"
else
  echo "verify FAILED ($unit), rc=$rc -> $log" >&2
fi
exit "$rc"

#!/usr/bin/env bash
# unit-start.sh: record a unit's scope baseline (the working tree's current HEAD)
# so bin/check-scope.sh can attribute only THIS unit's changes (its commits plus
# staged/unstaged edits) and ignore other concurrent units' files in a shared
# tree. Call it when assigning a unit, before the role starts work.
#
# The baseline is written to $TEAM_DIR/base/<unit> (per-run when TEAM_RUN_ID is
# set, else the legacy .team/base/<unit>). The value is a commit hash in the
# WORKING TREE's history, since that is where check-scope runs.
#
# Usage: bin/unit-start.sh <unit> [working-tree-dir]
#   working-tree-dir defaults to $PWD. Run it in (or point it at) the unit's
#   working tree, not the orchestrator clone, when they differ (--workdir runs).
#
# Exit: 0 = recorded, 2 = usage/setup error.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
unit="${1:?usage: unit-start.sh <unit> [working-tree-dir]}"
dir="${2:-$PWD}"

printf '%s' "$unit" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' \
  || { echo "invalid unit name '$unit'" >&2; exit 2; }

head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" \
  || { echo "not a git work tree (or no commits yet): $dir" >&2; exit 2; }

tree="$(cd "$dir" && pwd)"
mkdir -p "$TEAM_DIR/base"
printf '%s\n' "$head" > "$TEAM_DIR/base/$unit"
# Record the working tree beside the baseline hash so bin/check-scope.sh can
# resolve and operate in the right tree regardless of the cwd it is invoked from
# (guards the wrong-cwd silent pass, g3a). Sidecar, so the baseline file stays a
# bare commit hash for existing readers.
printf '%s\n' "$tree" > "$TEAM_DIR/base/$unit.tree"
echo "unit-start: baseline for '$unit' = $head  (tree: $tree)"

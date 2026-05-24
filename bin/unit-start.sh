#!/usr/bin/env bash
# unit-start.sh: record a unit's scope baseline (the working tree's current HEAD)
# so bin/check-scope.sh can attribute only THIS unit's changes (its commits plus
# staged/unstaged edits) and ignore other concurrent units' files in a shared
# tree. Call it when assigning a unit, before the role starts work.
#
# The baseline is written to $ORCH_HOME/.team/base/<unit> (a commit hash in the
# WORKING TREE's history, since that is where check-scope runs).
#
# Usage: bin/unit-start.sh <unit> [working-tree-dir]
#   working-tree-dir defaults to $PWD. Run it in (or point it at) the unit's
#   working tree, not the orchestrator clone, when they differ (--workdir runs).
#
# Exit: 0 = recorded, 2 = usage/setup error.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unit="${1:?usage: unit-start.sh <unit> [working-tree-dir]}"
dir="${2:-$PWD}"

printf '%s' "$unit" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' \
  || { echo "invalid unit name '$unit'" >&2; exit 2; }

head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" \
  || { echo "not a git work tree (or no commits yet): $dir" >&2; exit 2; }

mkdir -p "$repo/.team/base"
printf '%s\n' "$head" > "$repo/.team/base/$unit"
echo "unit-start: baseline for '$unit' = $head  (tree: $(cd "$dir" && pwd))"

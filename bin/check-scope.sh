#!/usr/bin/env bash
# check-scope.sh: reject a unit's changes that touch off-limits paths or fall
# outside its declared scope. Reads `scope:` and `off-limits:` from
# tasks/<unit>.md and compares against the changed files in the CURRENT git tree.
# Deterministic enforcement of "surgical changes / stay in your lane".
#
# Usage: bin/check-scope.sh <unit> [base-ref]
#   run from inside the unit's git working tree. base-ref defaults to the
#   upstream merge-base if set, else only uncommitted/untracked changes.
#
# Exit: 0 = within scope, 1 = violation, 2 = usage/setup error.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unit="${1:?usage: check-scope.sh <unit> [base-ref]}"
base="${2:-}"
brief="$repo/tasks/$unit.md"
[ -f "$brief" ] || { echo "no task brief: tasks/$unit.md" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git tree: $PWD" >&2; exit 2; }

[ -n "$base" ] || base="$(git merge-base HEAD '@{upstream}' 2>/dev/null || true)"

changed="$({
  [ -n "$base" ] && git diff --name-only "$base"...HEAD
  git diff --name-only
  git diff --name-only --cached
  git ls-files --others --exclude-standard
} | sort -u | sed '/^$/d')"

off="$(grep -m1 '^off-limits:' "$brief" | sed 's/^off-limits:[[:space:]]*//')"
scope="$(grep -m1 '^scope:' "$brief" | sed 's/^scope:[[:space:]]*//')"
norm() { printf '%s' "$1" | tr ',' ' '; }

fail=0

if [ -n "${off// /}" ] && [ "$off" != "-" ]; then
  for pat in $(norm "$off"); do
    hit="$(printf '%s\n' "$changed" | grep -F -- "$pat" || true)"
    [ -n "$hit" ] && { echo "OFF-LIMITS touched ($pat):"; printf '%s\n' "$hit"; fail=1; }
  done
fi

if [ -n "${scope// /}" ] && [ "$scope" != "-" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    inscope=0
    for pat in $(norm "$scope"); do
      case "$f" in $pat|$pat*|*/$pat*) inscope=1; break;; esac
    done
    [ "$inscope" -eq 0 ] && { echo "OUT OF SCOPE: $f"; fail=1; }
  done <<< "$changed"
fi

n="$(printf '%s' "$changed" | grep -c . || true)"
if [ "$fail" -eq 0 ]; then
  echo "scope OK ($unit): $n changed file(s) within scope"
else
  echo "scope CHECK FAILED ($unit)" >&2
fi
exit "$fail"

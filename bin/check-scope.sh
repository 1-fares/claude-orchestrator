#!/usr/bin/env bash
# check-scope.sh: reject a unit's changes that touch off-limits paths or fall
# outside its declared scope. Reads `scope:` and `off-limits:` from
# tasks/<unit>.md and compares against the changed files in the CURRENT git tree.
# Deterministic enforcement of "surgical changes / stay in your lane".
#
# Matching is path-aware (not substring): a pattern matches a file when it is the
# same path, a parent directory of it, a bare basename equal to the file's name,
# or a glob that matches it. So off-limits "slugify.py" does NOT match
# "test_slugify.py". Scope "." means the whole tree. Ephemeral build artifacts
# (__pycache__, *.pyc, .pytest_cache, node_modules, .mypy_cache, .DS_Store) are
# ignored.
#
# Note on serialized units in one tree: a unit's changed-set is everything not
# committed, so it sweeps in any other un-committed unit's files. Commit each
# unit before checking the next, or use per-unit git worktrees.
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
} | sort -u | sed '/^$/d' \
  | grep -Ev '(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|node_modules)(/|$)|\.pyc$|(^|/)\.DS_Store$' || true)"

off="$(grep -m1 '^off-limits:' "$brief" | sed 's/^off-limits:[[:space:]]*//')"
scope="$(grep -m1 '^scope:' "$brief" | sed 's/^scope:[[:space:]]*//')"
norm() { printf '%s' "$1" | tr ',' ' '; }

# path_matches <file> <pattern>: 0 if the pattern matches the file (path-aware).
path_matches() {
  local f="$1" p="${2%/}"
  [ "$p" = "." ] && return 0                      # whole tree
  [ "$f" = "$p" ] && return 0                      # exact path
  case "$f" in "$p"/*) return 0 ;; esac            # file under directory p
  case "$p" in
    */*) : ;;                                      # p has a slash: no basename match
    *)   [ "$(basename "$f")" = "$p" ] && return 0 ;;   # bare name: match basename
  esac
  case "$p" in *'*'*) case "$f" in $p) return 0 ;; esac ;; esac   # glob
  return 1
}

fail=0

if [ -n "${off// /}" ] && [ "$off" != "-" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for pat in $(norm "$off"); do
      if path_matches "$f" "$pat"; then echo "OFF-LIMITS touched: $f (pattern: $pat)"; fail=1; break; fi
    done
  done <<< "$changed"
fi

if [ -n "${scope// /}" ] && [ "$scope" != "-" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    inscope=0
    for pat in $(norm "$scope"); do path_matches "$f" "$pat" && { inscope=1; break; }; done
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

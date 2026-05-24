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
# Per-unit attribution: the changed-set reflects THIS unit's work, derived from a
# baseline ref (the unit's HEAD at assignment, recorded by bin/unit-start.sh into
# .team/base/<unit>; falls back to an explicit base-ref arg, then the upstream
# merge-base). With a baseline, only the unit's commits + staged + unstaged
# changes are checked, so other un-committed units in a shared tree no longer
# pollute the result. Without any baseline (true greenfield first unit), the
# changed-set also includes untracked files, which are legitimately this unit's.
# For parallel units, per-unit git worktrees remain the cleanest isolation.
#
# Usage: bin/check-scope.sh <unit> [base-ref]
#   run from inside the unit's git working tree. base-ref defaults to the
#   upstream merge-base if set, else only uncommitted/untracked changes.
#
# Exit: 0 = within scope, 1 = violation, 2 = usage/setup error.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
unit="${1:?usage: check-scope.sh <unit> [base-ref]}"
base="${2:-}"
brief="$repo/tasks/$unit.md"
[ -f "$brief" ] || { echo "no task brief: tasks/$unit.md" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git tree: $PWD" >&2; exit 2; }

# Resolve a per-unit baseline so the changed-set reflects THIS unit's work, not
# the whole tree. Order: explicit base-ref arg, recorded .team/base/<unit>, the
# upstream merge-base. A stale/garbage ref is ignored.
basefile="$TEAM_DIR/base/$unit"
[ -n "$base" ] || { [ -f "$basefile" ] && base="$(cat "$basefile" 2>/dev/null || true)"; }
[ -n "$base" ] || base="$(git merge-base HEAD '@{upstream}' 2>/dev/null || true)"
[ -n "$base" ] && ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 && base=""

ignore='(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|node_modules)(/|$)|\.pyc$|(^|/)\.DS_Store$'
if [ -n "$base" ]; then
  # Known baseline: attribute only the unit's committed + staged + unstaged
  # (tracked) changes. Tree-wide untracked files belong to other concurrent
  # units and are not attributable here, so they are excluded. This is the fix
  # for the shared-tree false-positive (another unit's un-committed files were
  # being charged against this unit).
  changed="$({
    git diff --name-only "$base"...HEAD
    git diff --name-only
    git diff --name-only --cached
  } | sort -u | sed '/^$/d' | grep -Ev "$ignore" || true)"
else
  # No baseline (true greenfield first unit): everything uncommitted/untracked is
  # legitimately this unit's, so include untracked files too.
  changed="$({
    git diff --name-only
    git diff --name-only --cached
    git ls-files --others --exclude-standard
  } | sort -u | sed '/^$/d' | grep -Ev "$ignore" || true)"
fi

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

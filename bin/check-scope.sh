#!/usr/bin/env bash
# check-scope.sh: reject a unit's changes that touch off-limits paths or fall
# outside its declared scope. Reads `scope:` and `off-limits:` from
# tasks/<unit>.md and compares against the changes ATTRIBUTED TO THIS UNIT.
# Deterministic enforcement of "surgical changes / stay in your lane".
#
# Matching is path-aware (not substring): a pattern matches a file when it is the
# same path, a parent directory of it, a bare basename equal to the file's name,
# or a glob that matches it. So off-limits "slugify.py" does NOT match
# "test_slugify.py". Scope "." means the whole tree. Ephemeral build artifacts
# (__pycache__, *.pyc, .pytest_cache, node_modules, .mypy_cache, .DS_Store) are
# ignored.
#
# ---------------------------------------------------------------------------
# Per-unit attribution (the shared-tree problem)
# ---------------------------------------------------------------------------
# When several units share ONE working tree, "what changed in this tree" is not
# "what this unit changed". Two ways foreign work used to be charged to a unit:
#   1. Foreign COMMITTED files: `git diff <base>...HEAD` spans every commit made
#      since the baseline, including other units' commits.
#   2. Foreign UNCOMMITTED files: `git diff` / `git diff --cached` are tree-wide,
#      so another role's edits to tracked files landed in the checked set.
#
# The changed-set is therefore built from two independently-attributed halves.
#
# COMMITS, over `<base>..HEAD` (merge commits skipped; their content reaches the
# range through their parents), in precedence order:
#   * An explicit commit list at $TEAM_DIR/commits/<unit> (one commit-ish per
#     line; `#` comments and blanks ignored) attributes exactly those commits.
#     Use it to retrofit attribution onto commits that were made without a
#     trailer, and for any workflow that would rather record hashes than edit
#     commit messages.
#   * Otherwise, if ANY commit in the range carries a `Unit:` trailer, the range
#     is treated as marked, and ONLY commits whose message has a trailer line
#     `Unit: <unit>` (case-insensitive key) are attributed. Foreign commits,
#     marked for another unit or unmarked, are ignored.
#   * Otherwise every commit in the range is attributed. This is the
#     per-unit-worktree / single-unit case, where there is no foreign work to
#     confuse, and it preserves the historic behaviour of this script.
#   The trailer is the preferred mechanism because it survives rebase,
#   cherry-pick and amend, needs no side-car state, and is visible in `git log`.
#   Record it by ending the commit message with a line: `Unit: <unit>`.
#   NOTE: in a shared tree, a unit whose commits carry neither a trailer nor a
#   commit-list entry falls back to "every commit since the baseline" and can
#   still be charged for another unit's commits. Marking is what buys isolation.
#
# UNCOMMITTED changes:
#   * With a claim file at $TEAM_DIR/claims/<unit> (one path, directory or glob
#     per line; `#` comments and blanks ignored), only staged, unstaged and
#     untracked paths matching a claim are attributed.
#   * With no claim file, but a marked commit range (i.e. the tree is shared and
#     is using markers), NO uncommitted change is attributed: the script cannot
#     tell whose it is, and guessing is what produced the false failures. A unit
#     that wants its uncommitted work checked must claim it.
#   * With neither claims nor markers (the worktree case), staged and unstaged
#     TRACKED changes are attributed, as before. Untracked files are not: in a
#     shared tree they usually belong to another role.
#   * With no baseline at all (a true greenfield first unit, no commits to
#     compare against), everything uncommitted AND untracked is attributed,
#     since it can only be this unit's.
#
# An empty attributed set is reported as a WARNING on stderr, not a silent pass:
# a gate that inspected nothing must never look like a gate that found nothing.
#
# Baseline order: explicit base-ref arg, then $TEAM_DIR/base/<unit> (written by
# bin/unit-start.sh at assignment), then the upstream merge-base. A stale or
# unresolvable ref is ignored.
#
# Usage: bin/check-scope.sh <unit> [base-ref]
#   Run from inside the unit's git working tree.
#
# Exit: 0 = within scope, 1 = violation, 2 = usage/setup error.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
unit="${1:?usage: check-scope.sh <unit> [base-ref]}"
base="${2:-}"

# The unit name is interpolated into an ERE below; keep it to characters that are
# literal there (alphanumerics, underscore, hyphen).
printf '%s' "$unit" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' \
  || { echo "invalid unit name '$unit'" >&2; exit 2; }

# Prefer this run's per-run brief ($TEAM_DIR/tasks), fall back to shared $repo/tasks
# (legacy, or briefs left there), so concurrent runs do not read each other's brief.
brief="$TEAM_DIR/tasks/$unit.md"
[ -f "$brief" ] || brief="$repo/tasks/$unit.md"
[ -f "$brief" ] || { echo "no task brief for '$unit' (looked in $TEAM_DIR/tasks and $repo/tasks)" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git tree: $PWD" >&2; exit 2; }

basefile="$TEAM_DIR/base/$unit"
[ -n "$base" ] || { [ -f "$basefile" ] && base="$(cat "$basefile" 2>/dev/null || true)"; }
[ -n "$base" ] || base="$(git merge-base HEAD '@{upstream}' 2>/dev/null || true)"
[ -n "$base" ] && ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 && base=""

claimfile="$TEAM_DIR/claims/$unit"
commitfile="$TEAM_DIR/commits/$unit"
ignore='(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|node_modules)(/|$)|\.pyc$|(^|/)\.DS_Store$'

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

# --- attribute the unit's commits ------------------------------------------
marked_range=0
commit_mode="all-since-baseline"
commit_files=""
ncommits=0
add_commit_files() {
  ncommits=$((ncommits + 1))
  commit_files="$commit_files$(git show --pretty=format: --name-only "$1")
"
}
if [ -f "$commitfile" ]; then
  commit_mode="explicit list"
  while IFS= read -r c; do
    c="$(printf '%s' "$c" | sed -e 's/#.*//' -e 's/[[:space:]]//g')"
    [ -n "$c" ] || continue
    if git rev-parse --verify --quiet "${c}^{commit}" >/dev/null 2>&1; then
      add_commit_files "$c"
    else
      echo "check-scope: commit '$c' in $commitfile is not in this tree; ignoring" >&2
    fi
  done < "$commitfile"
elif [ -n "$base" ]; then
  if git log --format='%B' "$base..HEAD" 2>/dev/null \
      | grep -Eqi '^Unit:[[:space:]]*[A-Za-z0-9][A-Za-z0-9_-]*[[:space:]]*$'; then
    marked_range=1
    commit_mode="marked trailer"
  fi
  for c in $(git rev-list --no-merges "$base..HEAD" 2>/dev/null); do
    if [ "$marked_range" -eq 1 ]; then
      git show -s --format='%B' "$c" \
        | grep -Eqi "^Unit:[[:space:]]*${unit}[[:space:]]*$" || continue
    fi
    add_commit_files "$c"
  done
fi

# --- attribute the unit's uncommitted changes -------------------------------
uncommitted=""
claim_mode="none"
if [ -z "$base" ]; then
  claim_mode="greenfield (no baseline: all uncommitted+untracked)"
  uncommitted="$({ git diff --name-only; git diff --name-only --cached; \
                   git ls-files --others --exclude-standard; } 2>/dev/null)"
elif [ -f "$claimfile" ]; then
  claim_mode="claims file"
  all_dirty="$({ git diff --name-only; git diff --name-only --cached; \
                 git ls-files --others --exclude-standard; } 2>/dev/null | sort -u)"
  claims="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$claimfile" | sed '/^$/d')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      if path_matches "$f" "$pat"; then uncommitted="$uncommitted$f
"; break; fi
    done <<< "$claims"
  done <<< "$all_dirty"
elif [ "$marked_range" -eq 1 ] || [ -f "$commitfile" ]; then
  claim_mode="none (attributed commits, unclaimed uncommitted work ignored)"
else
  claim_mode="legacy (tracked uncommitted attributed)"
  uncommitted="$({ git diff --name-only; git diff --name-only --cached; } 2>/dev/null)"
fi

changed="$(printf '%s\n%s\n' "$commit_files" "$uncommitted" \
  | sort -u | sed '/^$/d' | grep -Ev "$ignore" || true)"

off="$(grep -m1 '^off-limits:' "$brief" | sed 's/^off-limits:[[:space:]]*//')"
scope="$(grep -m1 '^scope:' "$brief" | sed 's/^scope:[[:space:]]*//')"
norm() { printf '%s' "$1" | tr ',' ' '; }

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

# How the set was derived, so a pass can be read as "checked N files", never as
# an unexplained zero.
printf 'check-scope: unit=%s base=%s commits=%d(%s) uncommitted=%s files=%d\n' \
  "$unit" "${base:0:12}" "$ncommits" "$commit_mode" "$claim_mode" "$n" >&2

if [ "$n" -eq 0 ]; then
  echo "WARNING: no changes attributed to '$unit'; this gate inspected nothing." >&2
  echo "  If the unit has committed, mark its commits with a 'Unit: $unit' trailer," >&2
  echo "  list them in $commitfile, claim uncommitted paths in $claimfile," >&2
  echo "  or pass an explicit base-ref." >&2
fi

if [ "$fail" -eq 0 ]; then
  echo "scope OK ($unit): $n changed file(s) within scope"
else
  echo "scope CHECK FAILED ($unit)" >&2
fi
exit "$fail"

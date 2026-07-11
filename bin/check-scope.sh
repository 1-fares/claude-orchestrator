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

# Resolve the intended working tree from the baseline stamp's sidecar, written by
# bin/unit-start.sh, and operate there regardless of cwd (g3a). Without this a run
# from the wrong cwd (e.g. the orchestrator clone instead of the unit's tree)
# attributed the wrong tree's files, or nothing, and still exited 0. The sidecar
# is optional: legacy stamps and the greenfield first unit have none, and then the
# current working directory is used, as before.
basefile="$TEAM_DIR/base/$unit"
treefile="$TEAM_DIR/base/$unit.tree"
if [ -f "$treefile" ]; then
  recorded_tree="$(cat "$treefile" 2>/dev/null || true)"
  if [ -n "$recorded_tree" ] && [ -d "$recorded_tree" ] \
     && git -C "$recorded_tree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cd "$recorded_tree" || { echo "cannot cd to recorded tree '$recorded_tree' for '$unit'" >&2; exit 2; }
  else
    echo "check-scope: recorded working tree for '$unit' is unusable: '$recorded_tree'" >&2
    echo "  (from $treefile). Re-run bin/unit-start.sh from the unit's tree." >&2
    exit 2
  fi
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git tree: $PWD" >&2; exit 2; }

# Baseline resolution, tracking where the base came from so an unresolvable value
# is handled by origin: a stamp that does not resolve in this tree is the wrong
# tree (g3a, hard error); a stale explicit-arg or upstream ref is tolerated.
base_from_stamp=0
if [ -z "$base" ] && [ -f "$basefile" ]; then
  base="$(cat "$basefile" 2>/dev/null || true)"
  [ -n "$base" ] && base_from_stamp=1
fi
[ -n "$base" ] || base="$(git merge-base HEAD '@{upstream}' 2>/dev/null || true)"
if [ -n "$base" ] && ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
  if [ "$base_from_stamp" -eq 1 ]; then
    echo "check-scope: baseline commit '$base' (from $basefile) is not in the tree at $PWD." >&2
    echo "  check-scope must run in the unit's working tree; this looks like the wrong tree." >&2
    echo "  Record the tree with bin/unit-start.sh so cwd no longer matters." >&2
    exit 2
  fi
  base=""   # stale explicit-arg or upstream ref: ignore, as before
fi

# A missing baseline is genuine greenfield ONLY when the unit has no committed
# work to bound. If HEAD history already carries this unit's commits (a `Unit:`
# trailer) but no stamp is visible, the stamp is missing, not absent by design:
# the trailer path would find commits=0 and the gate would scan nothing (g3b).
# Fail loudly rather than silently fall through to greenfield.
if [ -z "$base" ] \
   && git log --format='%B' HEAD 2>/dev/null \
        | grep -Eqi "^Unit:[[:space:]]*${unit}[[:space:]]*$"; then
  echo "check-scope: no baseline for '$unit' (looked for $basefile), yet HEAD carries" >&2
  echo "  commits marked 'Unit: $unit'. Without a baseline the commit range cannot be" >&2
  echo "  bounded and the gate would inspect nothing. Run bin/unit-start.sh for '$unit'" >&2
  echo "  in its working tree, or pass an explicit base-ref." >&2
  exit 2
fi

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
# The explicit commit list and the Unit: trailer are UNIONED, not mutually
# exclusive (g3c). Previously an explicit list SHORT-CIRCUITED trailer matching,
# so recording one new sha in $TEAM_DIR/commits/<unit> silently dropped every
# commit the unit had already marked with a trailer. Both sources now contribute;
# commits are de-duplicated by resolved sha. The baseline fallback (every commit
# since the baseline) still applies ONLY when NEITHER source is active, preserving
# the g2 attribution semantics.
marked_range=0
commit_files=""
ncommits=0
seen_shas=" "
add_commit_files() {
  local sha
  sha="$(git rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null)" || return 0
  case "$seen_shas" in *" $sha "*) return 0 ;; esac   # already attributed
  seen_shas="$seen_shas$sha "
  ncommits=$((ncommits + 1))
  commit_files="$commit_files$(git show --pretty=format: --name-only "$sha")
"
}

explicit_used=0
if [ -f "$commitfile" ]; then
  explicit_used=1
  while IFS= read -r c; do
    c="$(printf '%s' "$c" | sed -e 's/#.*//' -e 's/[[:space:]]//g')"
    [ -n "$c" ] || continue
    if git rev-parse --verify --quiet "${c}^{commit}" >/dev/null 2>&1; then
      add_commit_files "$c"
    else
      echo "check-scope: commit '$c' in $commitfile is not in this tree; ignoring" >&2
    fi
  done < "$commitfile"
fi

trailer_used=0
if [ -n "$base" ] \
   && git log --format='%B' "$base..HEAD" 2>/dev/null \
        | grep -Eqi '^Unit:[[:space:]]*[A-Za-z0-9][A-Za-z0-9_-]*[[:space:]]*$'; then
  marked_range=1
  trailer_used=1
  for c in $(git rev-list --no-merges "$base..HEAD" 2>/dev/null); do
    git show -s --format='%B' "$c" \
      | grep -Eqi "^Unit:[[:space:]]*${unit}[[:space:]]*$" || continue
    add_commit_files "$c"
  done
fi

# Baseline fallback: only when neither an explicit list nor a marked range is in
# play (the per-unit-worktree / single-unit case, no foreign work to confuse).
if [ "$explicit_used" -eq 0 ] && [ "$trailer_used" -eq 0 ] && [ -n "$base" ]; then
  for c in $(git rev-list --no-merges "$base..HEAD" 2>/dev/null); do
    add_commit_files "$c"
  done
fi

if [ "$explicit_used" -eq 1 ] && [ "$trailer_used" -eq 1 ]; then
  commit_mode="explicit list + marked trailer"
elif [ "$explicit_used" -eq 1 ]; then
  commit_mode="explicit list"
elif [ "$trailer_used" -eq 1 ]; then
  commit_mode="marked trailer"
else
  commit_mode="all-since-baseline"
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

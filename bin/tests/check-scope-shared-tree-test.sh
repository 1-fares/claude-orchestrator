#!/usr/bin/env bash
# check-scope-shared-tree-test.sh: regression test for per-unit attribution in
# bin/check-scope.sh when several units share ONE working tree.
#
# The defect: check-scope charged a unit for files it never touched.
#   1. Foreign COMMITTED files. `git diff <base>...HEAD` spans every commit made
#      since the baseline, including other units' commits.
#   2. Foreign UNCOMMITTED files. `git diff` / `git diff --cached` are tree-wide,
#      so another role's edits to tracked files landed in the checked set.
# Both made a unit fail on paths outside its own work.
#
# What is asserted here:
#   - a unit is not failed by another unit's committed files;
#   - a unit is not failed by another unit's uncommitted files;
#   - real violations by the unit itself are still caught (off-limits and
#     out-of-scope), in every attribution mode;
#   - the legacy / per-unit-worktree layout (no markers, no claims) behaves as
#     it did before;
#   - an explicit commit list attributes unmarked commits retroactively, still
#     catches that unit's own violations, and reports an unknown commit;
#   - a claim file attributes only the paths it names;
#   - an empty attributed set warns loudly instead of passing silently.
#
# Every fixture is a throwaway git repo under mktemp. Nothing depends on this
# clone's history, and no path outside the temp dir is read or written.
#
# Usage: bin/tests/check-scope-shared-tree-test.sh
# Exit:  0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
cs="$repo/bin/check-scope.sh"
[ -f "$cs" ] || { echo "missing check-scope.sh at $cs" >&2; exit 2; }

pass=0; fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# new_case <name>: fresh work tree (WT) + fresh team state dir (TD).
new_case() {
  CASE="$tmproot/$1"; WT="$CASE/tree"; TD="$CASE/team"
  mkdir -p "$WT" "$TD/tasks" "$TD/base" "$TD/claims" "$TD/commits"
  git -C "$WT" init -q
  git -C "$WT" config user.email tester@example.invalid
  git -C "$WT" config user.name  Tester
  git -C "$WT" config commit.gpgsign false
}

brief() { # brief <unit> <scope> <off-limits>
  printf 'unit: %s\nverify: true\nscope: %s\noff-limits: %s\ndepends-on: -\n' \
    "$1" "$2" "$3" > "$TD/tasks/$1.md"
}

seed() { # seed: initial commit, returns nothing; sets $BASE
  mkdir -p "$WT/src" "$WT/docs" "$WT/restricted"
  echo seed > "$WT/seed.txt"
  echo doc  > "$WT/docs/foreign.md"
  git -C "$WT" add -A >/dev/null
  git -C "$WT" commit -q -m "seed"
  BASE="$(git -C "$WT" rev-parse HEAD)"
}

baseline() { printf '%s\n' "$BASE" > "$TD/base/$1"; }

commit_unmarked() { git -C "$WT" add -A >/dev/null; git -C "$WT" commit -q -m "$1"; }
commit_marked()   { git -C "$WT" add -A >/dev/null; git -C "$WT" commit -q -m "$1

Unit: $2"; }

run_cs() { # run_cs <unit> [base-ref] ; stdout+stderr combined, exit in $?
  local rc out
  out="$( ( cd "$WT" && env -u TEAM_RUN_ID TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
      bash "$cs" "$@" ) 2>&1 )"; rc=$?
  # drop team-env.sh's TEAM_DIR-override notice; it is not part of the gate output
  printf '%s' "$out" | grep -v '^team-env:'
  return $rc
}

expect_exit() { # expect_exit <want> <label> <output> <got>
  if [ "$4" -eq "$1" ]; then ok "$2"
  else bad "$2" "want exit $1, got $4; output: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

echo "check-scope shared-tree attribution"

# ---------------------------------------------------------------------------
# 1. Foreign COMMITTED files must not fail this unit.
#    Another unit commits docs/foreign.md after the baseline; our unit's own
#    (marked) commit touches only src/, which is its scope.
# ---------------------------------------------------------------------------
new_case foreign-committed
seed; baseline demo-unit
echo changed > "$WT/docs/foreign.md"; commit_unmarked "other unit's work"
echo a > "$WT/src/allowed.txt";       commit_marked "demo work" demo-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 0 "foreign committed file does not fail the unit" "$out" "$rc"

# ---------------------------------------------------------------------------
# 2. Foreign UNCOMMITTED files must not fail this unit.
#    Another role has an unstaged edit to a tracked file sitting in the tree.
# ---------------------------------------------------------------------------
new_case foreign-uncommitted
seed; baseline demo-unit
echo a > "$WT/src/allowed.txt"; commit_marked "demo work" demo-unit
echo "another role's edit" >> "$WT/docs/foreign.md"   # unstaged, tracked, foreign
echo "another role's new file" > "$WT/docs/untracked.md"
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 0 "foreign uncommitted file does not fail the unit" "$out" "$rc"

# ---------------------------------------------------------------------------
# 3. The unit's OWN out-of-scope commit is still caught (strict mode).
# ---------------------------------------------------------------------------
new_case own-out-of-scope
seed; baseline demo-unit
echo x > "$WT/docs/mine.md"; commit_marked "demo strays" demo-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 1 "unit's own out-of-scope commit still fails" "$out" "$rc"
case "$out" in *"OUT OF SCOPE: docs/mine.md"*) ok "names the offending path" ;;
  *) bad "names the offending path" "output: $out" ;; esac

# ---------------------------------------------------------------------------
# 4. The unit's OWN off-limits commit is still caught (strict mode).
# ---------------------------------------------------------------------------
new_case own-off-limits
seed; baseline demo-unit
echo x > "$WT/restricted/off.txt"; commit_marked "demo strays" demo-unit
brief demo-unit "." "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 1 "unit's own off-limits commit still fails" "$out" "$rc"

# ---------------------------------------------------------------------------
# 5. Legacy / per-unit-worktree layout: no markers anywhere, no claim file.
#    Every commit since the baseline and every uncommitted tracked edit is the
#    unit's, so behaviour is unchanged: a stray file still fails.
# ---------------------------------------------------------------------------
new_case legacy-worktree-commit
seed; baseline demo-unit
echo x > "$WT/docs/mine.md"; commit_unmarked "demo work, no marker"
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 1 "legacy mode: unmarked out-of-scope commit still fails" "$out" "$rc"

new_case legacy-worktree-uncommitted
seed; baseline demo-unit
echo "stray edit" >> "$WT/docs/foreign.md"  # unstaged edit to a TRACKED file
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 1 "legacy mode: unmarked uncommitted edit still fails" "$out" "$rc"

# ---------------------------------------------------------------------------
# 6. Claimed uncommitted changes ARE attributed; unclaimed foreign ones are not.
# ---------------------------------------------------------------------------
new_case claims
seed; baseline demo-unit
echo a > "$WT/src/allowed.txt"; commit_marked "demo work" demo-unit
echo x > "$WT/docs/mine.md"                            # claimed, out of scope
echo "another role's edit" >> "$WT/docs/foreign.md"    # NOT claimed
printf 'docs/mine.md\n' > "$TD/claims/demo-unit"
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 1 "claimed out-of-scope uncommitted file fails the unit" "$out" "$rc"
case "$out" in *"docs/foreign.md"*) bad "unclaimed foreign file stays out of the set" "output: $out" ;;
  *) ok "unclaimed foreign file stays out of the set" ;; esac

# ---------------------------------------------------------------------------
# 7. An empty attributed set must warn, not pass silently.
#    (The unit has a baseline but no commits and no claims.)
# ---------------------------------------------------------------------------
new_case empty-attribution
seed; baseline demo-unit
echo "another role's edit" >> "$WT/docs/foreign.md"
echo a > "$WT/src/other.txt"; commit_marked "someone else's unit" other-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 0 "empty attribution does not fail" "$out" "$rc"
case "$out" in *WARNING*|*warning*) ok "empty attribution warns loudly" ;;
  *) bad "empty attribution warns loudly" "no warning in: $out" ;; esac

# ---------------------------------------------------------------------------
# 8. An explicit base-ref argument still works (CLI compatibility).
# ---------------------------------------------------------------------------
new_case explicit-base
seed; baseline demo-unit
echo changed > "$WT/docs/foreign.md"; commit_unmarked "other unit's work"
echo a > "$WT/src/allowed.txt";       commit_marked "demo work" demo-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit "$BASE")"; rc=$?
expect_exit 0 "explicit base-ref argument still accepted" "$out" "$rc"

# ---------------------------------------------------------------------------
# 9. Explicit commit list: attributes UNMARKED commits, retroactively.
#    This is the retrofit path for commits already made without a trailer.
#    The unit's own commit is in scope; a foreign commit is not listed.
# ---------------------------------------------------------------------------
new_case commit-list-clean
seed; baseline demo-unit
echo changed > "$WT/docs/foreign.md"; commit_unmarked "other unit's work"
echo a > "$WT/src/allowed.txt";       commit_unmarked "demo work, no trailer"
mine="$(git -C "$WT" rev-parse HEAD)"
printf '# this unit only\n%s\n' "$mine" > "$TD/commits/demo-unit"
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 0 "explicit commit list excludes a foreign unmarked commit" "$out" "$rc"

# ...and it still catches the unit's own violation.
new_case commit-list-violation
seed; baseline demo-unit
echo x > "$WT/docs/mine.md"; commit_unmarked "demo strays, no trailer"
mine="$(git -C "$WT" rev-parse HEAD)"
printf '%s\n' "$mine" > "$TD/commits/demo-unit"
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 1 "explicit commit list still catches the unit's violation" "$out" "$rc"

# A bad hash is reported, not silently dropped into a green pass.
new_case commit-list-bad-hash
seed; baseline demo-unit
printf '%s\n' "0000000000000000000000000000000000000000" > "$TD/commits/demo-unit"
brief demo-unit "src/" "restricted/"
out="$(run_cs demo-unit)"; rc=$?
expect_exit 0 "unknown commit in the list does not fail the gate" "$out" "$rc"
case "$out" in *"is not in this tree"*) ok "unknown commit is reported" ;;
  *) bad "unknown commit is reported" "output: $out" ;; esac

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

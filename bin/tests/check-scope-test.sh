#!/usr/bin/env bash
# check-scope-test.sh: regression tests for the g3 defects in bin/check-scope.sh
# and its baseline-stamp contract with bin/unit-start.sh.
#
# Defects covered (each observed in production, each fails before the fix):
#   g3a  Run from the WRONG cwd (not the unit's working tree) the gate resolved
#        no baseline, reported 0 changed files, and EXITED 0 -- a unit could pass
#        having inspected nothing. Fix: a stamp that does not resolve in this tree
#        is a hard error; and when unit-start.sh recorded the tree (a .tree
#        sidecar), check-scope cd's there and operates correctly regardless of cwd.
#   g3b  With the baseline stamp missing but the unit's commits carrying `Unit:`
#        trailers, the trailer path could not bound a range and found commits=0,
#        silently scanning nothing. Fix: error loudly. Genuine greenfield (no
#        baseline, no trailered commits) still attributes uncommitted work.
#
# Every fixture is a throwaway git repo under mktemp; nothing outside is touched.
#
# Usage: bin/tests/check-scope-test.sh
# Exit:  0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
cs="$repo/bin/check-scope.sh"
us="$repo/bin/unit-start.sh"
[ -f "$cs" ] || { echo "missing check-scope.sh at $cs" >&2; exit 2; }
[ -f "$us" ] || { echo "missing unit-start.sh at $us" >&2; exit 2; }

pass=0; fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

git_init() { # git_init <dir>
  git -C "$1" init -q
  git -C "$1" config user.email tester@example.invalid
  git -C "$1" config user.name  Tester
  git -C "$1" config commit.gpgsign false
}

new_case() { # fresh work tree (WT), an unrelated OTHER tree, fresh team dir (TD)
  CASE="$tmproot/$1"; WT="$CASE/tree"; OT="$CASE/other"; TD="$CASE/team"
  mkdir -p "$WT" "$OT" "$TD/tasks" "$TD/base" "$TD/claims" "$TD/commits"
  git_init "$WT"; git_init "$OT"
  # give the OTHER tree its own history, so the WT baseline sha is absent there
  echo other > "$OT/other.txt"; git -C "$OT" add -A >/dev/null
  git -C "$OT" commit -q -m "unrelated"
}

brief() { # brief <unit> <scope> <off-limits>
  printf 'unit: %s\nverify: true\nscope: %s\noff-limits: %s\ndepends-on: -\n' \
    "$1" "$2" "$3" > "$TD/tasks/$1.md"
}

seed() { mkdir -p "$WT/src"; echo seed > "$WT/seed.txt"
  git -C "$WT" add -A >/dev/null; git -C "$WT" commit -q -m "seed"
  BASE="$(git -C "$WT" rev-parse HEAD)"; }

commit_marked() { git -C "$WT" add -A >/dev/null; git -C "$WT" commit -q -m "$1

Unit: $2"; }

# run_cs <cwd> <unit> [args...]: run check-scope from <cwd>, combined out, exit $?
run_cs() {
  local cwd="$1"; shift
  local rc out
  out="$( ( cd "$cwd" && env -u TEAM_RUN_ID TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
      bash "$cs" "$@" ) 2>&1 )"; rc=$?
  printf '%s' "$out" | grep -v '^team-env:'
  return $rc
}

expect_exit() { # expect_exit <want> <label> <output> <got>
  if [ "$4" -eq "$1" ]; then ok "$2"
  else bad "$2" "want exit $1, got $4; output: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

echo "check-scope g3 baseline/cwd contract"

# ---------------------------------------------------------------------------
# g3a-1: wrong cwd, stamp present but no .tree sidecar -> hard error, not exit 0.
# ---------------------------------------------------------------------------
new_case wrong-cwd-hard-error
seed; printf '%s\n' "$BASE" > "$TD/base/demo-unit"    # bare hash, no sidecar
echo a > "$WT/src/a.txt"; commit_marked "work" demo-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs "$OT" demo-unit)"; rc=$?              # run from the WRONG tree
expect_exit 2 "wrong cwd with an unresolvable stamp is a hard error" "$out" "$rc"
case "$out" in *"wrong tree"*|*"not in the tree"*) ok "wrong-tree message is emitted" ;;
  *) bad "wrong-tree message is emitted" "output: $out" ;; esac

# ---------------------------------------------------------------------------
# g3a-2: with the .tree sidecar (written by unit-start.sh) check-scope operates
#        in the recorded tree regardless of cwd, and attributes correctly.
# ---------------------------------------------------------------------------
new_case wrong-cwd-recovers-via-sidecar
seed
env -u TEAM_RUN_ID TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
  bash "$us" demo-unit "$WT" >/dev/null 2>&1        # writes base + .tree sidecar
echo a > "$WT/src/a.txt"; commit_marked "work" demo-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs "$OT" demo-unit)"; rc=$?              # still from the WRONG cwd
expect_exit 0 "sidecar lets the gate run in the right tree from any cwd" "$out" "$rc"
case "$out" in *"src/a.txt"*|*"1 changed file"*) ok "attributes the unit's own commit" ;;
  *) bad "attributes the unit's own commit" "output: $out" ;; esac

# unit-start.sh actually wrote the sidecar with the tree path.
new_case unit-start-writes-sidecar
seed
env -u TEAM_RUN_ID TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
  bash "$us" demo-unit "$WT" >/dev/null 2>&1
if [ -f "$TD/base/demo-unit.tree" ] && [ "$(cat "$TD/base/demo-unit.tree")" = "$(cd "$WT" && pwd)" ]; then
  ok "unit-start.sh records the working tree in the .tree sidecar"
else
  bad "unit-start.sh records the working tree in the .tree sidecar" \
      "sidecar: $(cat "$TD/base/demo-unit.tree" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# g3a-3: sidecar points at an unusable path -> hard error (never a silent pass).
# ---------------------------------------------------------------------------
new_case sidecar-unusable
seed; printf '%s\n' "$BASE" > "$TD/base/demo-unit"
printf '%s\n' "$CASE/does-not-exist" > "$TD/base/demo-unit.tree"
brief demo-unit "src/" "restricted/"
out="$(run_cs "$WT" demo-unit)"; rc=$?
expect_exit 2 "an unusable recorded tree is a hard error" "$out" "$rc"

# ---------------------------------------------------------------------------
# g3b-1: missing stamp but trailered commits exist -> hard error, not silent
#        greenfield. (No baseline file, no upstream: the study-tree topology.)
# ---------------------------------------------------------------------------
new_case missing-stamp-with-trailers
seed                                                # base stamp deliberately NOT written
echo a > "$WT/src/a.txt"; commit_marked "work" demo-unit
brief demo-unit "src/" "restricted/"
out="$(run_cs "$WT" demo-unit)"; rc=$?
expect_exit 2 "missing baseline with trailered commits is a hard error" "$out" "$rc"
case "$out" in *"no baseline"*|*"baseline"*) ok "missing-baseline message is emitted" ;;
  *) bad "missing-baseline message is emitted" "output: $out" ;; esac

# ---------------------------------------------------------------------------
# g3b-2: genuine greenfield (no baseline, no trailered commits, uncommitted work)
#        still attributes the uncommitted files and passes.
# ---------------------------------------------------------------------------
new_case genuine-greenfield
seed                                                # no base stamp
echo a > "$WT/src/a.txt"                            # uncommitted, in scope, no trailer
brief demo-unit "src/ seed.txt" "restricted/"
out="$(run_cs "$WT" demo-unit)"; rc=$?
expect_exit 0 "greenfield still attributes uncommitted work" "$out" "$rc"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

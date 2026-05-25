#!/usr/bin/env bash
# concurrency-test.sh: prove the BUG-concurrent-runs-shared-ledger fix. Two runs
# in one clone must not collide on the ledger or task briefs, and the gates must
# read the per-run brief (falling back to the shared $repo/tasks in legacy mode).
# No role spawns: this exercises the path logic directly and fast.
#
# Usage: tests/b9/concurrency-test.sh

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
UNIT="concu1"   # a throwaway unit name unlikely to clash with real briefs

P=0; F=0; declare -a FAILED=()
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; P=$((P+1)); return 0; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; F=$((F+1)); FAILED+=("$1"); return 0; }
expect_eq(){ [ "$1" = "$2" ] && pass "$3" || fail "$3 (want '$1' got '$2')"; }

cleanup(){ rm -rf "$repo/.team-cA" "$repo/.team-cB"; rm -f "$repo/tasks/$UNIT.md"; }
trap cleanup EXIT
cleanup

# verify-unit run in $repo (a git tree) under a given TEAM_RUN_ID; echoes its rc.
gate_rc(){ ( cd "$repo" && TEAM_RUN_ID="$1" ./bin/verify-unit.sh "$UNIT" >/dev/null 2>&1; echo $? ); }
gate_rc_legacy(){ ( cd "$repo" && env -u TEAM_RUN_ID ./bin/verify-unit.sh "$UNIT" >/dev/null 2>&1; echo $? ); }

mkbrief(){ # $1=path-dir $2=verify-rc
  mkdir -p "$1"
  printf 'unit: %s\nverify: exit %s\nscope: .\n' "$UNIT" "$2" > "$1/$UNIT.md"
}

echo "== concurrency isolation test (run-id cA / cB)"

echo "--- per-run brief takes precedence over the shared one"
mkbrief "$repo/.team-cA/tasks" 0      # per-run A: verify exits 0
mkbrief "$repo/tasks" 42              # shared: verify exits 42
expect_eq 0 "$(gate_rc cA)" "gate reads run A's per-run brief (exit 0), not shared (42)"

echo "--- falls back to the shared brief when no per-run brief exists"
rm -f "$repo/.team-cA/tasks/$UNIT.md"
expect_eq 42 "$(gate_rc cA)" "gate falls back to shared brief (exit 42)"

echo "--- legacy mode (no TEAM_RUN_ID) reads the shared brief"
expect_eq 42 "$(gate_rc_legacy)" "legacy gate reads shared brief (exit 42)"

echo "--- two concurrent runs never read each other's brief"
mkbrief "$repo/.team-cA/tasks" 0     # A: exit 0
mkbrief "$repo/.team-cB/tasks" 7     # B: exit 7
expect_eq 0 "$(gate_rc cA)" "run A gate reads A's brief (exit 0)"
expect_eq 7 "$(gate_rc cB)" "run B gate reads B's brief (exit 7)"

echo "--- ledger writes are per-run (roster.sh keys on \$TEAM_DIR)"
(
  cd "$repo"
  for rid in cA cB; do
    TEAM_DIR="$repo/.team-$rid" bash -c '
      . "'"$repo"'/bin/lib/roster.sh"
      decision_log_append "ledger marker for '"$rid"'"
      roster_append "+marker-'"$rid"'"
    '
  done
)
grep -q "marker for cA" "$repo/.team-cA/state.md" && ! grep -q "marker for cB" "$repo/.team-cA/state.md" \
  && pass "run A ledger has only A's content" || fail "run A ledger isolation"
grep -q "marker for cB" "$repo/.team-cB/state.md" && ! grep -q "marker for cA" "$repo/.team-cB/state.md" \
  && pass "run B ledger has only B's content" || fail "run B ledger isolation"

echo
echo "================ concurrency test: $P passed, $F failed ================"
if [ "$F" -gt 0 ]; then printf 'FAILED:\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
exit 0

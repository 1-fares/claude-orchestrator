#!/usr/bin/env bash
# concurrency-test.sh: prove the BUG-concurrent-runs-shared-ledger fix. Two runs
# in one clone must not collide on the ledger or task briefs, and the gates must
# read the per-run brief (falling back to the shared $repo/tasks in legacy mode).
# No role spawns: this exercises the path logic directly and fast.
#
# Isolation: sources bin/tests/lib/isolate.sh before team-env.sh. The gates run in
# a scratch clone at a fixed path whose bin/ is a symlink to this clone's bin/, so
# the run dirs (.team-cA, .team-cB), the legacy .team/ and the shared tasks/ brief
# are created there and removed with it; nothing is written into this clone.
#
# Usage: tests/b9/concurrency-test.sh

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=/dev/null
. "$repo/bin/tests/lib/isolate.sh"   # throwaway TEAM_RUN_ID/TEAM_TMUX, before team-env
# shellcheck source=/dev/null
. "$repo/bin/team-env.sh"
isolate_assert
UNIT="concu1"   # a throwaway unit name unlikely to clash with real briefs

P=0; F=0; declare -a FAILED=()
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; P=$((P+1)); return 0; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; F=$((F+1)); FAILED+=("$1"); return 0; }
expect_eq(){ [ "$1" = "$2" ] && pass "$3" || fail "$3 (want '$1' got '$2')"; }

rm -rf /tmp/orch-test-concurrency
mkdir /tmp/orch-test-concurrency || { echo "ABORT: cannot create the scratch dir"; exit 2; }
trap 'rm -rf /tmp/orch-test-concurrency' EXIT
S=/tmp/orch-test-concurrency   # the scratch clone; rm -rf removes the bin link, not its target
ln -s "$repo/bin" "$S/bin"

# verify-unit run in the scratch clone under a given TEAM_RUN_ID; echoes its rc. The team
# variables this shell exported are cleared, as a separate run.sh would have none: with this
# test's TEAM_DIR inherited, team-env refuses to derive the run's own dir.
gate_env=(env -u TEAM_DIR -u TEAM_SESSION -u TEAM_PORT -u INTER_SESSION_PORT)
gate_rc(){ ( cd "$S" && "${gate_env[@]}" TEAM_RUN_ID="$1" ./bin/verify-unit.sh "$UNIT" >/dev/null 2>&1; echo $? ); }
gate_rc_legacy(){ ( cd "$S" && "${gate_env[@]}" -u TEAM_RUN_ID ./bin/verify-unit.sh "$UNIT" >/dev/null 2>&1; echo $? ); }

mkbrief(){ # $1=path-dir $2=verify-rc
  mkdir -p "$1"
  printf 'unit: %s\nverify: exit %s\nscope: .\n' "$UNIT" "$2" > "$1/$UNIT.md"
}

echo "== concurrency isolation test (run-id cA / cB, scratch clone $S)"

echo "--- per-run brief takes precedence over the shared one"
mkbrief "$S/.team-cA/tasks" 0      # per-run A: verify exits 0
mkbrief "$S/tasks" 42              # shared: verify exits 42
expect_eq 0 "$(gate_rc cA)" "gate reads run A's per-run brief (exit 0), not shared (42)"

echo "--- falls back to the shared brief when no per-run brief exists"
rm -f /tmp/orch-test-concurrency/.team-cA/tasks/concu1.md
expect_eq 42 "$(gate_rc cA)" "gate falls back to shared brief (exit 42)"

echo "--- legacy mode (no TEAM_RUN_ID) reads the shared brief"
expect_eq 42 "$(gate_rc_legacy)" "legacy gate reads shared brief (exit 42)"
[ -f "$S/.team/verify/$UNIT.log" ] && pass "legacy gate wrote its log under the scratch clone's .team/" \
  || fail "legacy gate log not at $S/.team/verify/$UNIT.log"

echo "--- two concurrent runs never read each other's brief"
mkbrief "$S/.team-cA/tasks" 0     # A: exit 0
mkbrief "$S/.team-cB/tasks" 7     # B: exit 7
expect_eq 0 "$(gate_rc cA)" "run A gate reads A's brief (exit 0)"
expect_eq 7 "$(gate_rc cB)" "run B gate reads B's brief (exit 7)"

echo "--- ledger writes are per-run (roster.sh keys on \$TEAM_DIR)"
(
  cd "$S"
  for rid in cA cB; do
    TEAM_DIR="$S/.team-$rid" bash -c '
      . "'"$repo"'/bin/lib/roster.sh"
      decision_log_append "ledger marker for '"$rid"'"
      roster_append "+marker-'"$rid"'"
    '
  done
)
grep -q "marker for cA" "$S/.team-cA/state.md" && ! grep -q "marker for cB" "$S/.team-cA/state.md" \
  && pass "run A ledger has only A's content" || fail "run A ledger isolation"
grep -q "marker for cB" "$S/.team-cB/state.md" && ! grep -q "marker for cA" "$S/.team-cB/state.md" \
  && pass "run B ledger has only B's content" || fail "run B ledger isolation"

echo
echo "================ concurrency test: $P passed, $F failed ================"
if [ "$F" -gt 0 ]; then printf 'FAILED:\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
exit 0

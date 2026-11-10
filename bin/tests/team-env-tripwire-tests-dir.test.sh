#!/usr/bin/env bash
# team-env-tripwire-tests-dir.test.sh: the team-env.sh test-isolation tripwire (exit 97 when a test
# caller carries a run id that is not a test id; docs/incident-2026-07-11-test-cleanup-wiped-live-run.md)
# covers callers under the clone's tests/ directory as well as bin/tests/.
#
# The callers run in a scratch clone at a fixed path: bin/team-env.sh, bin/lib and bin/tests/lib there
# are symlinks to this clone's files, so the real team-env.sh runs with TEAM_REPO set to the scratch
# clone and every caller path below is under it. Nothing is written into this clone.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$repo/bin/tests/lib/isolate.sh"   # unsets inherited team variables; each caller sets its own run id

rm -rf /tmp/orch-test-team-env-tripwire
mkdir /tmp/orch-test-team-env-tripwire || { echo "ABORT: cannot create the scratch dir"; exit 2; }
trap 'rm -rf /tmp/orch-test-team-env-tripwire' EXIT
S=/tmp/orch-test-team-env-tripwire
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

mkdir -p "$S/bin/tests" "$S/tests/b9" "$S/scripts" "$S/docs/tests"
ln -s "$repo/bin/team-env.sh" "$S/bin/team-env.sh"
ln -s "$repo/bin/lib" "$S/bin/lib"
ln -s "$repo/bin/tests/lib" "$S/bin/tests/lib"
# caller: sources team-env (through a relative path, the shape a test uses) and reports what it derived.
caller='#!/usr/bin/env bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$here"
while [ ! -e "$root/bin/team-env.sh" ]; do [ "$root" = / ] && exit 3; root="$(dirname "$root")"; done
. "$root/bin/team-env.sh"
echo "derived TEAM_DIR=$TEAM_DIR"'
for f in tests/b9/t.sh bin/tests/t.sh scripts/t.sh docs/tests/t.sh; do printf '%s\n' "$caller" > "$S/$f"; done
# an isolated caller under tests/: isolate.sh first, then team-env, then isolate_assert.
printf '%s\n' '#!/usr/bin/env bash' '. "/tmp/orch-test-team-env-tripwire/bin/tests/lib/isolate.sh"' \
  '. "/tmp/orch-test-team-env-tripwire/bin/team-env.sh"' 'isolate_assert' 'echo "derived TEAM_DIR=$TEAM_DIR"' > "$S/tests/b9/iso.sh"

# run_caller <run id or -> <script> [cwd]: rc and output of the caller; "-" leaves TEAM_RUN_ID unset.
run_caller() {
  local rid="$1" script="$2" cwd="${3:-$S}"
  if [ "$rid" = - ]; then out="$(cd "$cwd" && env -u TEAM_RUN_ID bash "$script" 2>&1)"; rc=$?
  else out="$(cd "$cwd" && TEAM_RUN_ID="$rid" bash "$script" 2>&1)"; rc=$?; fi
}

run_caller livefoo "$S/tests/b9/t.sh"
[ "$rc" = 97 ] && grep -q 'is not a test id' <<<"$out" \
  && ok "tests/ caller with a non-test run id: exit 97" || no "tests/ caller with a non-test run id: rc $rc: $out"
run_caller - "$S/tests/b9/t.sh"
[ "$rc" = 97 ] && ok "tests/ caller in legacy mode (no run id): exit 97" || no "tests/ caller in legacy mode: rc $rc: $out"
run_caller livefoo ./t.sh "$S/tests/b9"
[ "$rc" = 97 ] && ok "tests/ caller started by a relative path from its own directory: exit 97" \
  || no "tests/ caller by a relative path: rc $rc: $out"
run_caller livefoo "$S/tests/b9/iso.sh"
[ "$rc" = 0 ] && grep -q "derived TEAM_DIR=$S/.team-test" <<<"$out" \
  && ok "tests/ caller that sources isolate.sh first: rc 0, throwaway TEAM_DIR" || no "isolated tests/ caller: rc $rc: $out"
run_caller test123 "$S/tests/b9/t.sh"
[ "$rc" = 0 ] && ok "tests/ caller with a test run id: rc 0" || no "tests/ caller with a test run id: rc $rc: $out"
# controls: bin/tests/ still covered; a caller elsewhere, even under a directory named tests, is not.
run_caller livefoo "$S/bin/tests/t.sh"
[ "$rc" = 97 ] && ok "control: bin/tests/ caller with a non-test run id: exit 97" || no "bin/tests/ caller: rc $rc: $out"
run_caller livefoo "$S/scripts/t.sh"
[ "$rc" = 0 ] && grep -q "derived TEAM_DIR=$S/.team-livefoo" <<<"$out" \
  && ok "control: a caller outside tests/ keeps its run id (rc 0)" || no "caller outside tests/: rc $rc: $out"
run_caller livefoo "$S/docs/tests/t.sh"
[ "$rc" = 0 ] && ok "control: a tests/ directory below the clone root is not the clone's tests/ (rc 0)" \
  || no "docs/tests/ caller: rc $rc: $out"

printf '\nteam-env-tripwire-tests-dir: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Regression test for the structural TEAM_DIR safety guard (PART B), born from the
# 2026-06-16 run-dir-wipe incident:
#   - bin/lib/team-dir-guard.sh: tdg_is_live_run_dir / tdg_guard_rmrf /
#     tdg_assert_scratch_team_dir refuse a destructive op on a live `.team-*` run dir.
#   - bin/team-env.sh: refuses to SILENTLY override a pre-set TEAM_DIR (the exact
#     mechanism that moved a test's TEAM_DIR onto the live run dir).
#
# Asserts: the guard flags a `.team-*` dir under an orchestrator clone and a dir
# with a live-claude `active`, but allows a plain scratch dir; tdg_guard_rmrf
# refuses the former and removes the latter; team-env returns non-zero and does NOT
# move a conflicting pre-set TEAM_DIR (so a trap rm would hit the scratch, not the
# live run); TEAM_DIR_ALLOW_OVERRIDE=1 honors the explicit dir.
# HERMETIC + SAFE: isolated temp fixtures only; team-env is exercised with a FAKE
# non-live TEAM_RUN_ID so the canonical path it derives is a scratch, never a live run.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT   # SCRATCH is a plain mktemp dir, never a .team-* run dir
fail=0; ok(){ printf '  ok   %s\n' "$1"; }; bad(){ printf '  FAIL %s\n' "$1"; fail=1; }

# shellcheck disable=SC1091
. "$repo/bin/lib/team-dir-guard.sh"

# Fixture: a fake orchestrator clone with a `.team-fake` run dir under it.
mkdir -p "$SCRATCH/fakeclone/bin" "$SCRATCH/fakeclone/.team-fake"
: > "$SCRATCH/fakeclone/bin/team-env.sh"
# Fixture: a plain scratch dir (not a run dir).
mkdir -p "$SCRATCH/plain"

# 1) tdg_is_live_run_dir: yes for a .team-* under a clone, no for a plain dir.
tdg_is_live_run_dir "$SCRATCH/fakeclone/.team-fake" && ok "is_live_run_dir: flags .team-* under an orchestrator clone" || bad "did not flag .team-* run dir"
tdg_is_live_run_dir "$SCRATCH/plain" && bad "wrongly flagged a plain scratch dir" || ok "is_live_run_dir: allows a plain scratch dir"

# 2) a dir with a live-claude active entry is flagged even off the .team-* name.
mkdir -p "$SCRATCH/byactive"; printf '%s\t@0\tx\n' "$$" > "$SCRATCH/byactive/active"  # $$ is bash, not claude
tdg_is_live_run_dir "$SCRATCH/byactive" && bad "flagged a dir whose active pid is NOT claude" || ok "is_live_run_dir: a non-claude active pid does not falsely flag"
# 2b) the same from a script whose PATH contains "claude" (a clone in a directory named claude-orchestrator):
#     a bash is not claude however it was started, so its args line must not decide.
mkdir -p "$SCRATCH/claude-clone" "$SCRATCH/byclaudepath"
printf '%s\n' '. "$1"; printf "%s\t@0\tx\n" "$$" > "$2/active"; tdg_is_live_run_dir "$2" && echo FLAGGED || echo CLEAR' > "$SCRATCH/claude-clone/row.sh"
r="$(bash "$SCRATCH/claude-clone/row.sh" "$repo/bin/lib/team-dir-guard.sh" "$SCRATCH/byclaudepath")"
[ "$r" = CLEAR ] && ok "is_live_run_dir: a bash started from a path containing claude does not falsely flag" || bad "flagged a bash started from a claude-named path (got '$r')"
# 2c) positive controls: a live process named claude (comm), and one whose argv0 is claude, still flag.
#     The comm stand-in is a copy of bash named claude run with argv0 "notclaude" (so only comm says claude);
#     `; true` keeps bash -c from exec-ing sleep, which would rename the process.
mkdir -p "$SCRATCH/cbin" "$SCRATCH/bycomm" "$SCRATCH/byargv0"; cp "$(command -v bash)" "$SCRATCH/cbin/claude"
bash -c 'exec -a notclaude "$0" -c "sleep 30; true"' "$SCRATCH/cbin/claude" & P_COMM=$!
bash -c 'exec -a claude sleep 30' & P_ARGV0=$!
trap 'kill "$P_COMM" "$P_ARGV0" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
sleep 0.3
printf '%s\t@0\tx\n' "$P_COMM" > "$SCRATCH/bycomm/active"; printf '%s\t@0\tx\n' "$P_ARGV0" > "$SCRATCH/byargv0/active"
tdg_is_live_run_dir "$SCRATCH/bycomm" && ok "is_live_run_dir: a live process named claude (comm) flags" || bad "did not flag a live process named claude"
tdg_is_live_run_dir "$SCRATCH/byargv0" && ok "is_live_run_dir: a live process with argv0 claude flags" || bad "did not flag a live process with argv0 claude"
kill "$P_COMM" "$P_ARGV0" 2>/dev/null; wait "$P_COMM" "$P_ARGV0" 2>/dev/null
# 2d) a native install exec'd by its real path (CLAUDE_BIN=~/.local/share/claude/versions/<v>): comm and argv0's
#     basename are the version, so only the executable's location says claude. Both shapes flag: the versions path
#     itself, and a non-claude-named link to it (argv0 says neither, only /proc/<pid>/exe does).
mkdir -p "$SCRATCH/share/claude/versions" "$SCRATCH/byver" "$SCRATCH/bylink"; cp "$(command -v bash)" "$SCRATCH/share/claude/versions/9.9.9"
ln -s "$SCRATCH/share/claude/versions/9.9.9" "$SCRATCH/cbin/runner"
"$SCRATCH/share/claude/versions/9.9.9" -c 'sleep 30; true' & P_VER=$!
"$SCRATCH/cbin/runner" -c 'sleep 30; true' & P_LINK=$!
trap 'kill "$P_VER" "$P_LINK" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
sleep 0.3
printf '%s\t@0\tx\n' "$P_VER" > "$SCRATCH/byver/active"; printf '%s\t@0\tx\n' "$P_LINK" > "$SCRATCH/bylink/active"
tdg_is_live_run_dir "$SCRATCH/byver" && ok "is_live_run_dir: a claude exec'd by its versions path flags" || bad "did not flag a claude exec'd by its versions path (comm $(ps -o comm= -p "$P_VER"))"
if [ -e "/proc/$P_LINK/exe" ]; then
  tdg_is_live_run_dir "$SCRATCH/bylink" && ok "is_live_run_dir: a claude exec'd through a non-claude-named link flags (by its executable)" || bad "did not flag a claude exec'd through a link named runner"
fi
kill "$P_VER" "$P_LINK" 2>/dev/null; wait "$P_VER" "$P_LINK" 2>/dev/null

# 3) tdg_guard_rmrf: refuses the run dir, removes the plain dir.
tdg_guard_rmrf "$SCRATCH/fakeclone/.team-fake" 2>/dev/null && bad "guard_rmrf removed a run dir" || ok "guard_rmrf: REFUSES a .team-* run dir"
[ -d "$SCRATCH/fakeclone/.team-fake" ] && ok "guard_rmrf: the run dir still exists (not removed)" || bad "run dir was removed despite refusal"
tdg_guard_rmrf "$SCRATCH/plain" 2>/dev/null && ok "guard_rmrf: removes a plain scratch dir" || bad "guard_rmrf refused a plain dir"
[ ! -d "$SCRATCH/plain" ] && ok "guard_rmrf: plain dir actually removed" || bad "plain dir not removed"

# 4) team-env refuses to silently override a conflicting pre-set TEAM_DIR. Use a
#    FAKE non-live run id so the canonical path is a scratch (never the live run).
out="$(TEAM_RUN_ID="potest-$$" TEAM_DIR="$SCRATCH/preset" bash -c '. '"$repo"'/bin/team-env.sh 2>/dev/null; echo "RC=$?"; echo "TD=$TEAM_DIR"')"
grep -q 'RC=1' <<<"$out" && ok "team-env: returns non-zero on a conflicting pre-set TEAM_DIR" || { bad "team-env did not fail"; echo "$out"; }
grep -q "TD=$SCRATCH/preset" <<<"$out" && ok "team-env: leaves TEAM_DIR as pre-set (does NOT move it to the canonical/live run)" || { bad "team-env moved TEAM_DIR"; echo "$out"; }

# 5) TEAM_DIR_ALLOW_OVERRIDE=1 honors the explicit dir (rc 0, TEAM_DIR unchanged).
out2="$(TEAM_RUN_ID="potest-$$" TEAM_DIR="$SCRATCH/preset" TEAM_DIR_ALLOW_OVERRIDE=1 bash -c '. '"$repo"'/bin/team-env.sh 2>/dev/null; echo "RC=$?"; echo "TD=$TEAM_DIR"')"
grep -q 'RC=0' <<<"$out2" && grep -q "TD=$SCRATCH/preset" <<<"$out2" && ok "team-env: ALLOW_OVERRIDE honors the explicit dir" || { bad "ALLOW_OVERRIDE wrong"; echo "$out2"; }

# 6) tdg_assert_scratch_team_dir: passes for a temp dir, aborts (subshell exit 1) for a run dir.
( TEAM_DIR="$SCRATCH/plainok"; mkdir -p "$TEAM_DIR"; . "$repo/bin/lib/team-dir-guard.sh"; tdg_assert_scratch_team_dir ) 2>/dev/null \
  && ok "assert_scratch_team_dir: passes for an isolated temp dir" || bad "assert wrongly aborted on a temp dir"
( TEAM_DIR="$SCRATCH/fakeclone/.team-fake"; . "$repo/bin/lib/team-dir-guard.sh"; tdg_assert_scratch_team_dir ) 2>/dev/null \
  && bad "assert did NOT abort on a run dir" || ok "assert_scratch_team_dir: aborts when TEAM_DIR is a run dir"

if [ "$fail" -eq 0 ]; then echo "team-dir-guard: ALL PASS"; else echo "team-dir-guard: FAILED"; fi
exit "$fail"

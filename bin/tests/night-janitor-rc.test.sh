#!/usr/bin/env bash
# night-janitor-rc.test.sh: bin/night-janitor.sh's exit status.
# A dry run exited 1 on every run (note() returned the false `[ apply ] &&` of its last line, and
# the script ends on a note), so a cron-chain dry run read as a failure. Pinned here: dry run 0,
# --apply 0, an unknown flag 2, and a failed janitor.log write under --apply 1.
# The janitor runs from a COPY of bin/ in a sandbox repo, so run-dir resolution sees only the
# sandbox's .team-* dirs, never the live run. SRC=<tree> tests another tree's janitor (red run).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
SB="$(mktemp -d /tmp/njrc-XXXXXX)"
trap 'rm -rf -- "${SB:?}"' EXIT
R="$SB/repo"; mkdir -p "$R" "$SB/home" "$SB/attach"
cp -a "$SRC/bin" "$R/bin"
case "$R" in "$SB"/*) ;; *) echo "FATAL: sandbox repo not under the sandbox" >&2; exit 99 ;; esac
export NOTIFY_SINK="$SB/notify.sink" WATCH_ALERT_SINK="$SB/watch.sink"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# jan <run-id|-> <args...>: run the sandbox janitor; "-" leaves TEAM_RUN_ID unset (disk resolution).
jan(){ local r="$1"; shift
  if [ "$r" = - ]; then
    env -u TEAM_RUN_ID -u TEAM_DIR -u TEAM_DIR_ALLOW_OVERRIDE -u NJ_BUS_DIR -u NJ_DOCKER_BUILDER_PRUNE \
      HOME="$SB/home" GH_ATTACHMENTS_DIR="$SB/attach" TEAM_TMUX="ttnj$$" bash "$R/bin/night-janitor.sh" "$@" >"$SB/out" 2>&1
  else
    env -u TEAM_DIR -u TEAM_DIR_ALLOW_OVERRIDE -u NJ_BUS_DIR -u NJ_DOCKER_BUILDER_PRUNE TEAM_RUN_ID="$r" \
      HOME="$SB/home" GH_ATTACHMENTS_DIR="$SB/attach" TEAM_TMUX="ttnj$$" bash "$R/bin/night-janitor.sh" "$@" >"$SB/out" 2>&1
  fi
}
rc_is(){ local want="$1" label="$2"; shift 2; "$@"; local rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label: rc $rc"; else bad "$label: rc $rc, want $want"; sed 's/^/     | /' "$SB/out" | tail -5; fi; }

mkdir -p "$R/.team-rA"
rc_is 0 "dry run (sole run dir, TEAM_RUN_ID set)" jan rA
/usr/bin/grep -q 'night-janitor \[DRY-RUN\] done' "$SB/out" && ok "dry run printed its done line" || bad "dry run done line"
rc_is 0 "dry run, explicit --dry-run" jan rA --dry-run
rc_is 0 "dry run, run dir from disk (no TEAM_RUN_ID)" jan -
rc_is 0 "--apply" jan rA --apply
/usr/bin/grep -q 'night-janitor \[APPLY\] done' "$R/.team-rA/janitor.log" && ok "--apply wrote janitor.log" || bad "--apply janitor.log"
rc_is 2 "unknown flag refused" jan rA --bogus
# --apply with an unwritable janitor.log must still surface as a failure (note() keeps the write status).
chmod 400 "$R/.team-rA/janitor.log"
if [ -w "$R/.team-rA/janitor.log" ]; then ok "unwritable log case skipped (running as root)"; else
  rc_is 1 "--apply with an unwritable janitor.log fails" jan rA --apply; fi
chmod 600 "$R/.team-rA/janitor.log"

# A named run whose dir is missing is a failure with a message, not a success that cleaned nothing.
rc_is 1 "named run dir missing" jan rMissing --apply
/usr/bin/grep -q 'night-janitor: no run dir at .*\.team-rMissing' "$SB/out" && ok "missing run dir is named in the message" || bad "missing run dir message"
[ ! -e "$R/.team-rMissing" ] && ok "the missing run dir was not created" || bad "the missing run dir was created"

# Without TEAM_RUN_ID (cron) every run dir is cleaned, whatever its id, and a test's dir is skipped.
mkbaks(){ local d="$1" i; mkdir -p "$d"; for i in 1 2 3 4 5; do echo "bak $i" > "$d/state.md.bak-2026010${i}-000000"; touch -d "$((10 - i)) days ago" "$d/state.md.bak-2026010${i}-000000"; done; }
nbaks(){ local n=0 f; for f in "$1"/state.md.bak-*; do [ -f "$f" ] && n=$((n+1)); done; echo "$n"; }
mkbaks "$R/.team-rA"; mkbaks "$R/.team-other-id"; mkbaks "$R/.team"; mkbaks "$R/.team-test999"
: > "$R/.team-backup.log"   # a file named like a run dir is not one
rc_is 0 "cron --apply over several run dirs" jan - --apply
for d in .team-rA .team-other-id .team; do
  [ "$(nbaks "$R/$d")" -eq 3 ] && ok "cron: $d thinned to 3 baks" || bad "cron: $d has $(nbaks "$R/$d") baks, want 3"
  /usr/bin/grep -q "night-janitor \[APPLY\] run=$R/$d\$" "$R/$d/janitor.log" && ok "cron: $d has its own run line in its janitor.log" || bad "cron: $d janitor.log run line"
  /usr/bin/grep -q 'night-janitor \[APPLY\] done' "$R/$d/janitor.log" && ok "cron: $d janitor.log has the done line" || bad "cron: $d janitor.log done line"
done
[ "$(nbaks "$R/.team-test999")" -eq 5 ] && ok "cron: test run dir .team-test999 left alone" || bad "cron: test run dir touched"
[ ! -e "$R/.team-test999/janitor.log" ] && ok "cron: no janitor.log in the test run dir" || bad "cron: janitor.log written in the test run dir"

# A clone with no run dir at all: exit 1, not a silent success.
R2="$SB/repo2"; mkdir -p "$R2"; cp -a "$SRC/bin" "$R2/bin"
env -u TEAM_RUN_ID -u TEAM_DIR -u TEAM_DIR_ALLOW_OVERRIDE -u NJ_BUS_DIR -u NJ_DOCKER_BUILDER_PRUNE \
  HOME="$SB/home" GH_ATTACHMENTS_DIR="$SB/attach" TEAM_TMUX="ttnj$$" bash "$R2/bin/night-janitor.sh" --apply >"$SB/out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && /usr/bin/grep -q 'night-janitor: no run dir under' "$SB/out" && ok "no run dir at all: rc 1 with a message" \
  || bad "no run dir at all: rc $rc, want 1 ($(tail -1 "$SB/out"))"
echo
echo "night-janitor-rc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

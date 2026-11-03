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
    env -u TEAM_RUN_ID -u TEAM_DIR -u TEAM_DIR_ALLOW_OVERRIDE -u NJ_BUS_DIR \
      HOME="$SB/home" GH_ATTACHMENTS_DIR="$SB/attach" TEAM_TMUX="ttnj$$" bash "$R/bin/night-janitor.sh" "$@" >"$SB/out" 2>&1
  else
    env -u TEAM_DIR -u TEAM_DIR_ALLOW_OVERRIDE -u NJ_BUS_DIR TEAM_RUN_ID="$r" \
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
echo
echo "night-janitor-rc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

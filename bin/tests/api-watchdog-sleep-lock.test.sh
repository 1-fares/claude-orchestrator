#!/usr/bin/env bash
# The api-watchdog's loop sleep must neither delay TERM nor keep the singleton lock.
#
# Before: a foreground `sleep "$interval"` (30 s) inherited the flock fd 200. bash runs
# the TERM trap only after a foreground command ends, so a stop waited for the sleep; and
# after a SIGKILL the orphaned sleep kept the lock for the rest of its interval, so a
# relaunch in that window exited "already running" and no watchdog ran.
#
# Runs the REAL api-watchdog loop (not --once) against a stand-in tmux that reports no
# session, so each scan returns at once and the daemon spends its time in the sleep.
# Every process started here is stopped before exit. Scratch lives in one fixed
# directory, removed on exit; do not run two copies at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/tests/lib/isolate.sh"
rm -rf /tmp/orch-test-api-watchdog-sleep-lock
S=/tmp/orch-test-api-watchdog-sleep-lock
TD="$S/team"
mkdir -p "$S/bin" "$TD"
STARTED=""
cleanup() {
  local p
  for p in $STARTED; do kill -KILL "$p" 2>/dev/null; done
  rm -rf /tmp/orch-test-api-watchdog-sleep-lock
}
trap cleanup EXIT

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

printf '#!/usr/bin/env bash\nexit 1\n' > "$S/bin/tmux"   # no session: every scan is empty
chmod +x "$S/bin/tmux"

start_wd() {
  env -u NTFY_URL PATH="$S/bin:$PATH" TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
    API_WATCHDOG_LOCK="$S/lock" NOTIFY_SINK="$S/notify" \
    bash "$repo/bin/api-watchdog.sh" --interval 30 >> "$S/out" 2>&1 &
  WD=$!; STARTED="$STARTED $WD"
}
# sleep_child <pid>: the pid of <pid>'s `sleep` child, waiting up to 10 s for it.
sleep_child() {
  local i c
  for i in 1 2 3 4 5 6 7 8 9 10; do
    c="$(pgrep -P "$1" -x sleep | head -1)"
    [ -n "$c" ] && { echo "$c"; return 0; }
    sleep 1
  done
  return 1
}
holds_lock() { grep -q "$S/lock" <<<"$(ls -l "/proc/$1/fd" 2>/dev/null)"; }
lock_free() { flock -n "$S/lock" true; }

echo "1. the sleep child does not hold the lock; the daemon does"
start_wd
SC="$(sleep_child "$WD")" && STARTED="$STARTED $SC"
[ -n "$SC" ] && ok "daemon reached its loop sleep (child $SC)" || bad "no sleep child within 10 s: $(tail -3 "$S/out")"
holds_lock "$WD" && ok "the daemon holds the lock fd" || bad "the daemon does not hold the lock fd"
[ -n "$SC" ] && ! holds_lock "$SC" && ok "the sleep child does not hold the lock fd" || bad "the sleep child holds the lock fd"

echo "2. TERM is handled at once and the lock is released with the daemon"
kill -TERM "$WD"
gone=""
for i in 1 2 3 4 5; do kill -0 "$WD" 2>/dev/null || { gone=$i; break; }; sleep 1; done
[ -n "$gone" ] && [ "$gone" -le 2 ] && ok "daemon exited within ${gone}s of TERM (interval 30 s)" || bad "daemon still running ${gone:-5+}s after TERM"
lock_free && ok "lock free right after the exit" || bad "lock still held after TERM"
[ -n "$SC" ] && ! kill -0 "$SC" 2>/dev/null && ok "the sleep child ended with the daemon" || bad "the sleep child outlived the daemon"
grep -q 'api-watchdog: stopping' "$S/out" && ok "TERM ran the stop trap" || bad "no stop line"

echo "3. after a SIGKILL the orphaned sleep does not keep the lock"
start_wd
SC="$(sleep_child "$WD")" && STARTED="$STARTED $SC"
{ kill -KILL "$WD"; wait "$WD"; } 2>/dev/null; sleep 1
[ -n "$SC" ] && kill -0 "$SC" 2>/dev/null && ok "the sleep child is orphaned (still running)" || bad "no orphaned sleep to test with"
lock_free && ok "lock free although the orphaned sleep still runs" || bad "the orphaned sleep holds the lock"
start_wd
sleep 2
kill -0 "$WD" 2>/dev/null && ok "a relaunch runs (not 'already running')" || bad "relaunch exited: $(tail -2 "$S/out")"
kill -TERM "$WD" 2>/dev/null; sleep 1

echo
if [ "$fail" = 0 ]; then echo "api-watchdog-sleep-lock.test: PASS"; exit 0
else echo "api-watchdog-sleep-lock.test: FAIL"; exit 1; fi

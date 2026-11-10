#!/usr/bin/env bash
# tmux-watchdog keeps the team's daemons alive while the session runs. Pins two things:
#   1. host-ram-watchdog and disk-tmp-watchdog are restarted like the others (before,
#      they came back only at the next launch, add-role or start-orchestrator);
#   2. a restarted intake poller APPENDS to intake-poller.log (before, `>` truncated
#      the log of the run that died).
#
# Runs the REAL tmux-watchdog loop from a COPY of bin/ in which the two resource
# watchdogs are stand-ins that record their start and exit at once, so no real daemon
# is ever started. The other daemons are disabled by their opt-out variables; the intake
# poller is a stand-in script. tmux is a stand-in that reports a live session. Scratch
# lives in one fixed directory, removed on exit; do not run two copies at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/tests/lib/isolate.sh"
rm -rf /tmp/orch-test-tmux-watchdog-self-heal
S=/tmp/orch-test-tmux-watchdog-self-heal
R="$S/repo"; TD="$S/team"
HOLDER=""
cleanup() {
  [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null
  rm -rf /tmp/orch-test-tmux-watchdog-self-heal
}
trap cleanup EXIT
mkdir -p "$S/fakebin" "$R" "$TD"
cp -a "$repo/bin" "$R/bin"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

for n in host-ram-watchdog disk-tmp-watchdog; do
  printf '#!/usr/bin/env bash\necho "started" >> "%s/started-%s"\n' "$S" "$n" > "$R/bin/$n.sh"
  chmod +x "$R/bin/$n.sh"
done
printf 'print("poller ran")\n' > "$S/poller.py"
cat > "$S/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
case "${1:-}" in
  has-session) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$S/fakebin/tmux"
printf '1\t-\torchestrator\n' > "$TD/active"

# run_twd <seconds> [NAME=value ...]: the real loop, stopped by timeout.
run_twd() {
  local secs="$1"; shift
  env -u NTFY_URL PATH="$S/fakebin:$PATH" TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
    TMUX_WATCHDOG_INTERVAL_S=1 TMUX_WATCHDOG_SNAPSHOT_S=3600 NOTIFY_SINK="$S/notify" \
    API_WATCHDOG_DISABLED=1 COMPACT_WATCHDOG_DISABLED=1 OBSERVER_DISABLED=1 \
    PERMISSION_MODE_WATCHDOG_DISABLED=1 INTAKE_POLLER="$S/poller.py" "$@" \
    timeout "$secs" bash "$R/bin/tmux-watchdog.sh" >/dev/null 2>&1
  sleep 1   # the stand-ins and the loop's last sleep finish
}
starts() { local n; n="$(grep -c started "$S/started-$1" 2>/dev/null)"; echo "${n:-0}"; }

echo "1. both resource watchdogs are restarted while the session runs"
printf 'line from the run that died\n' > "$TD/intake-poller.log"
run_twd 4
[ "$(starts host-ram-watchdog)" -ge 1 ] && ok "host-ram-watchdog restarted ($(starts host-ram-watchdog)x)" || bad "host-ram-watchdog never restarted"
[ "$(starts disk-tmp-watchdog)" -ge 1 ] && ok "disk-tmp-watchdog restarted ($(starts disk-tmp-watchdog)x)" || bad "disk-tmp-watchdog never restarted"
grep -q 'SELF-HEAL: host-ram-watchdog was down' "$TD/audit/tmux.log" 2>/dev/null && ok "audit records the host-ram self-heal" || bad "no host-ram SELF-HEAL line"
grep -q 'SELF-HEAL: disk-tmp-watchdog was down' "$TD/audit/tmux.log" 2>/dev/null && ok "audit records the disk-tmp self-heal" || bad "no disk-tmp SELF-HEAL line"

echo "2. the intake poller's log is appended to, not truncated"
grep -q 'line from the run that died' "$TD/intake-poller.log" && ok "the previous run's log survives a restart" || bad "intake-poller.log was truncated"
grep -q 'poller ran' "$TD/intake-poller.log" && ok "the restarted poller writes to the same log" || bad "no output from the restarted poller"

echo "3. a live daemon (its lock held) is left alone"
: > "$S/started-host-ram-watchdog"
# One process holds the lock (the subshell execs sleep), so one kill releases it.
( exec 9>"$TD/host-ram-watchdog.lock"; flock 9; exec sleep 30 ) &
HOLDER=$!
sleep 1
run_twd 3
[ "$(starts host-ram-watchdog)" = 0 ] && ok "no restart while host-ram-watchdog holds its lock" || bad "restarted although its lock is held ($(starts host-ram-watchdog)x)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""

echo "4. the opt-out variables are honoured"
: > "$S/started-host-ram-watchdog"; : > "$S/started-disk-tmp-watchdog"
run_twd 3 HOST_RAM_WATCHDOG_DISABLED=1 DISK_TMP_WATCHDOG_DISABLED=1
[ "$(starts host-ram-watchdog)" = 0 ] && [ "$(starts disk-tmp-watchdog)" = 0 ] \
  && ok "no restart with HOST_RAM_WATCHDOG_DISABLED=1 / DISK_TMP_WATCHDOG_DISABLED=1" || bad "restarted despite the opt-out"

echo
if [ "$fail" = 0 ]; then echo "tmux-watchdog-self-heal.test: PASS"; exit 0
else echo "tmux-watchdog-self-heal.test: FAIL"; exit 1; fi

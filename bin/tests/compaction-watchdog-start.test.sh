#!/usr/bin/env bash
# compaction-watchdog start and stop.
# 1. Without TEAM_DIR it refuses to start (exit 1, says why) and writes nothing in its working directory, where
#    ${TEAM_DIR:-.} used to put its log, lock and pidfile. COMPACT_WATCHDOG_DISABLED=1 still exits 0.
# 2. Start-up types nothing: with a draft in the orchestrator's box, the first pass leaves the box alone (the canary
#    used to type /context with clear there on every start).
# 3. A TERM during the inter-pass sleep ends the daemon at once, the sleep child ends with it, and the lock is free
#    at once; the sleep child never holds the lock. Both sleep sites: a full pass and the no-targets branch.
# 4. A second start while a watchdog of the same code version holds the lock exits 0 at once, before the start line
#    and the canary, and leaves the pidfile alone; a holder on another code version is named as such.
# Runs the REAL daemon against a stand-in tmux. Every process started here is stopped before exit. Scratch lives in
# one fixed directory, removed on exit; do not run two copies at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rm -rf /tmp/orch-test-compaction-start
S=/tmp/orch-test-compaction-start
TD="$S/team"
mkdir -p "$S/bin" "$S/home" "$S/cwd" "$TD/health" "$TD/models"
STARTED=""
cleanup() {
  local p
  for p in $STARTED; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  rm -rf /tmp/orch-test-compaction-start
}
trap cleanup EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "  ok   $1"; }
bad() { n=$((n+1)); fail=1; echo "  FAIL $1"; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1: got [$2] want [$3]"; }

# Stand-in tmux. $S/mode "none": no session (the no-targets branch); "one": window 0 holds the orchestrator, an idle
# screen whose box shows $S/box. Every send-keys is logged to $S/keys.
cat > "$S/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
cmd="${1:-}"; shift || true
mode="$(cat "$FAKE_S/mode" 2>/dev/null)"
case "$cmd" in
  has-session)     [ "$mode" = one ] ;;
  list-sessions)   [ "$mode" = one ] && echo orch-sess ;;
  list-windows)    [ "$mode" = one ] && echo "0 orchestrator" ;;
  display-message) echo "claude 4242" ;;
  capture-pane)    printf '%s\n' '● standing by.' '  12% context used' '────────' "❯ $(cat "$FAKE_S/box" 2>/dev/null)" '────────' '  -- INSERT --' ;;
  send-keys)       printf '%s\n' "$*" >> "$FAKE_S/keys" ;;
esac
FAKE
chmod +x "$S/bin/tmux"

start_wd() { # start_wd <interval>: the daemon in the background, WD = its pid
  env -u NTFY_URL -u COMPACT_PRESERVE PATH="$S/bin:$PATH" HOME="$S/home" FAKE_S="$S" TEAM_DIR="$TD" TEAM_RUN_ID=testrun \
    NOTIFY_SINK="$S/notify" WATCH_ALERT_SINK="$S/watch" COMPACT_SOCKET=no-such-socket COMPACT_SESSION=orch-sess \
    COMPACT_SETTINGS_FILE="$S/no-settings" COMPACT_BUS_SINK="$S/bus" COMPACT_BUS_SEND="$S/no-sender" \
    COMPACT_CHECK_INTERVAL="$1" COMPACT_IDLE_SEC=0 COMPACT_PROBE_WAIT=0 \
    bash "$repo/bin/compaction-watchdog.sh" >> "$S/out" 2>&1 &
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
holds_lock() { grep -q "$TD/compaction-watchdog.lock" <<<"$(ls -l "/proc/$1/fd" 2>/dev/null)"; }
lock_free() { flock -n "$TD/compaction-watchdog.lock" true; }
cnt() { local c; c="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${c:-0}"; }
# stop_check <label>: TERM the daemon WD (sleep child SC) and check it is gone within 2 s with the lock free.
stop_check() {
  local i gone=""
  kill -TERM "$WD"
  for i in 1 2 3 4 5; do kill -0 "$WD" 2>/dev/null || { gone=$i; break; }; sleep 1; done
  [ -n "$gone" ] && [ "$gone" -le 2 ] && ok "$1: daemon exited within ${gone}s of TERM (interval 120 s)" || bad "$1: still running ${gone:-5+}s after TERM"
  lock_free && ok "$1: lock free right after the exit" || bad "$1: lock still held after TERM"
  [ -n "$SC" ] && ! kill -0 "$SC" 2>/dev/null && ok "$1: the sleep child ended with the daemon" || bad "$1: the sleep child outlived the daemon"
}

echo "== 1: TEAM_DIR is required"
out="$(cd "$S/cwd" && env -i PATH="$S/bin:$PATH" HOME="$S/home" timeout 20 bash "$repo/bin/compaction-watchdog.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "no TEAM_DIR: exit 1" || bad "no TEAM_DIR: exit $rc"
[[ "$out" == *"TEAM_DIR is not set; refusing to start"* ]] && ok "no TEAM_DIR: says why" || bad "no TEAM_DIR: output [$out]"
[ -z "$(ls -A "$S/cwd")" ] && ok "no TEAM_DIR: nothing written in the working directory" || bad "written in cwd: $(ls -A "$S/cwd")"
out="$(cd "$S/cwd" && env -i PATH="$S/bin:$PATH" HOME="$S/home" COMPACT_WATCHDOG_DISABLED=1 timeout 20 bash "$repo/bin/compaction-watchdog.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *disabled* ]] && ok "disabled without TEAM_DIR: exit 0" || bad "disabled: exit $rc [$out]"

echo "== 2 and 3: a full pass, then TERM in the sleep"
echo one > "$S/mode"; printf 'half a draft' > "$S/box"; : > "$S/keys"
start_wd 120
SC="$(sleep_child "$WD")" && STARTED="$STARTED $SC"
[ -n "$SC" ] && ok "daemon reached its inter-pass sleep (child $SC)" || bad "no sleep child within 10 s: $(tail -3 "$TD/compaction-watchdog.log" 2>/dev/null)"
chk "start-up typed nothing into the orchestrator pane holding a draft" "$(cnt . "$S/keys")" "0"
chk "the canary is pending, not run" "$(cnt 'canary: pending' "$TD/compaction-watchdog.log")" "1"
holds_lock "$WD" && ok "the daemon holds the lock fd" || bad "the daemon does not hold the lock fd"
[ -n "$SC" ] && ! holds_lock "$SC" && ok "the sleep child does not hold the lock fd" || bad "the sleep child holds the lock fd"

echo "== 4: a second start"
pid_before="$(cat "$TD/compaction-watchdog.pid" 2>/dev/null)"
t0=$SECONDS
out="$(env -u NTFY_URL PATH="$S/bin:$PATH" HOME="$S/home" FAKE_S="$S" TEAM_DIR="$TD" TEAM_RUN_ID=testrun NOTIFY_SINK="$S/notify" \
  COMPACT_SOCKET=no-such-socket COMPACT_SESSION=orch-sess timeout 20 bash "$repo/bin/compaction-watchdog.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ $((SECONDS - t0)) -le 5 ] && ok "same code version: exit 0 at once" || bad "second start: exit $rc after $((SECONDS - t0))s"
[[ "$out" == *"same code version"* ]] && ok "same code version: says so" || bad "second start output [$out]"
chk "no second start line" "$(cnt 'start: multi-target' "$TD/compaction-watchdog.log")" "1"
chk "no second canary line" "$(cnt 'canary:' "$TD/compaction-watchdog.log")" "1"
chk "the pidfile still names the first daemon" "$(cat "$TD/compaction-watchdog.pid" 2>/dev/null)" "$pid_before"
printf 'other-code\n' > "$TD/compaction-watchdog.pid.version"
out="$(env -u NTFY_URL PATH="$S/bin:$PATH" HOME="$S/home" FAKE_S="$S" TEAM_DIR="$TD" TEAM_RUN_ID=testrun NOTIFY_SINK="$S/notify" \
  COMPACT_SOCKET=no-such-socket COMPACT_SESSION=orch-sess timeout 20 bash "$repo/bin/compaction-watchdog.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"other or unknown code version"* ]] && ok "another code version holds the lock: exit 0, named" || bad "other version: exit $rc [$out]"
kill -0 "$WD" 2>/dev/null && ok "the first daemon still runs" || bad "the first daemon is gone"
stop_check "full pass"
chk "the draft is still in the box" "$(cat "$S/box")" "half a draft"

echo "== 3: the no-targets sleep"
echo none > "$S/mode"
start_wd 120
SC="$(sleep_child "$WD")" && STARTED="$STARTED $SC"
[ -n "$SC" ] && ok "no targets: daemon reached its sleep (child $SC)" || bad "no targets: no sleep child within 10 s"
stop_check "no targets"

[ "$fail" = 0 ] && echo "compaction-watchdog-start.test: PASS ($n)" || { echo "compaction-watchdog-start.test: FAIL"; exit 1; }

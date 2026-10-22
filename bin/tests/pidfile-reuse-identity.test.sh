#!/usr/bin/env bash
# Test: a pid read from a pidfile is signalled only when it is this run's daemon.
#
# After a reboot or pid wraparound a stale pidfile can name sshd, the SSM agent or any other
# process, and `kill -0` cannot tell. proc_pid_is_run_daemon requires the script in argv AND this
# run's TEAM_RUN_ID/TEAM_DIR in environ. Covered: the helper, team-spawn's _reap_prior_daemon, and
# bin/panic.sh end to end under a throwaway run id (HOME sandboxed so it cannot reach a live bus).
#
# PANIC=<path> runs section C against another panic.sh (for a red run against the old code).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PANIC="${PANIC:-$repo/bin/panic.sh}"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
alive(){ [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

# shellcheck source=bin/tests/lib/isolate.sh
. "$repo/bin/tests/lib/isolate.sh"
SB="$(mktemp -d /tmp/pidreuse-XXXXXX)"
RID="$TEAM_RUN_ID"
TD="$repo/.team-$RID"
export NOTIFY_SINK="$SB/notify.sink" WATCH_ALERT_SINK="$SB/watch.sink"
# start() runs in a $(...) subshell, so children are recorded in a file, not a variable.
KIDS="$SB/kids"
cleanup(){ local k; while read -r k; do pkill -9 -P "$k" 2>/dev/null; kill -9 "$k" 2>/dev/null || true; done < "$KIDS"
           rm -rf -- "${SB:?}" "${TD:?}"; }
trap cleanup EXIT
mkdir -p "$TD" "$SB/bin" "$SB/scripts" "$SB/home"; : > "$KIDS"

for n in compaction-watchdog observer chrome-supervisor; do
  printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$SB/bin/$n.sh"; chmod +x "$SB/bin/$n.sh"
done
printf 'import time\nwhile True: time.sleep(1)\n' > "$SB/scripts/poller.py"
cp "$SB/scripts/poller.py" "$SB/scripts/feedback-poller.py"

# start <run-id> <cmd...>: background a process carrying the given run id + dir in its environ.
start(){ local r="$1"; shift
  env TEAM_RUN_ID="$r" TEAM_DIR="$repo/.team-$r" "$@" >/dev/null 2>&1 & local p=$!
  echo "$p" >> "$KIDS"; echo "$p"; }

# Unit tests run as this throwaway run; never inherit the live TEAM_DIR/TEAM_RUN_ID.
export TEAM_RUN_ID="$RID" TEAM_DIR="$TD"
# shellcheck source=bin/lib/pid-identity.sh
. "$repo/bin/lib/pid-identity.sh"

echo "=== A: proc_pid_is_run_daemon ==="
REAL="$(start "$RID" bash "$SB/bin/observer.sh")"
UNREL="$(start "$RID" sleep 600)"
OTHER="$(start "other-$$" bash "$SB/bin/observer.sh")"
DECOY="$(start "$RID" bash -c "echo $SB/bin/observer.sh >/dev/null; sleep 600; true")"
TAIL="$(start "$RID" tail -f "$SB/bin/observer.sh")"
FBP="$(start "$RID" python3 -u "$SB/scripts/feedback-poller.py")"
TP="$(start "$RID" python3 -u "$SB/scripts/poller.py" --peer x)"
sleep 0.5
proc_pid_is_run_daemon "$REAL" "bin/observer.sh" && ok "this run's daemon is recognised" || no "real daemon recognised" ""
proc_pid_is_run_daemon "$UNREL" "bin/observer.sh" && no "unrelated sleep must not match" "" || ok "unrelated process (same run env) rejected"
proc_pid_is_run_daemon "$OTHER" "bin/observer.sh" && no "other run's daemon must not match" "" || ok "same script, other run rejected"
if grep -qF "$SB/bin/observer.sh" <<<"$( { tr '\0' ' ' < "/proc/$DECOY/cmdline"; } 2>/dev/null )"; then
  proc_pid_is_run_daemon "$DECOY" "bin/observer.sh" && no "decoy shell must not match" "" || ok "shell that only mentions the path rejected"
else no "decoy precondition: path in its argv" ""; fi
proc_pid_is_run_daemon "$TAIL" "bin/observer.sh" && no "tail -f on the script must not match" "" || ok "tail -f <script> (same run) rejected: only the program position counts"
proc_pid_is_run_daemon "$FBP" "scripts/poller.py" && no "feedback-poller must not match intake globs" "" \
  || ok "same-run feedback-poller rejected by the intake-poller globs"
proc_pid_is_run_daemon "$TP" "scripts/poller.py" && ok "python3 -u poller.py recognised (interpreter option skipped)" \
  || no "poller recognised" "$(tr '\0' ' ' < /proc/$TP/cmdline)"
proc_pid_is_run_daemon 1 "bin/observer.sh" && no "pid 1 must not match" "" || ok "pid 1 (unreadable environ) rejected"
proc_pid_is_run_daemon "" "bin/observer.sh" && no "empty pid must not match" "" || ok "empty pid rejected"
proc_pid_is_run_daemon "12x" "bin/observer.sh" && no "non-numeric pid must not match" "" || ok "non-numeric pid rejected"
( unset TEAM_RUN_ID TEAM_DIR; proc_pid_is_run_daemon "$REAL" "bin/observer.sh" ) && no "no run identity must refuse" "" \
  || ok "caller with no TEAM_RUN_ID/TEAM_DIR refuses"
pkill -9 -P "$DECOY" 2>/dev/null   # its `sleep 600` child would outlive it
kill -9 "$REAL" "$UNREL" "$OTHER" "$DECOY" "$TAIL" "$FBP" "$TP" 2>/dev/null; wait 2>/dev/null

echo "=== B: team-spawn _reap_prior_daemon ==="
UNREL="$(start "$RID" sleep 600)"; sleep 0.3
echo "$UNREL" > "$TD/compaction-watchdog.pid"
out="$( repo="$repo"; . "$repo/bin/lib/team-spawn.sh"; _reap_prior_daemon compaction-watchdog )"
sleep 0.3
alive "$UNREL" && ok "unrelated pid in the pidfile NOT signalled" || no "unrelated pid survives" "$out"
[ -f "$TD/compaction-watchdog.pid" ] && no "stale pidfile removed" "" || ok "stale pidfile removed"
grep -q "not signalled" <<<"$out" && ok "one line logged: $out" || no "stale-pidfile log line" "$out"
REAL="$(start "$RID" bash "$SB/bin/compaction-watchdog.sh")"; sleep 0.4
echo "$REAL" > "$TD/compaction-watchdog.pid"
out="$( repo="$repo"; . "$repo/bin/lib/team-spawn.sh"; _reap_prior_daemon compaction-watchdog )"
sleep 0.3; wait "$REAL" 2>/dev/null
alive "$REAL" && no "real daemon reaped" "$out" || ok "real daemon reaped ($out)"
kill -9 "$UNREL" 2>/dev/null; wait 2>/dev/null

echo "=== C: panic.sh end to end ($PANIC) ==="
UNREL="$(start "$RID" sleep 600)"
OBS="$(start "$RID" bash "$SB/bin/observer.sh")"
POLL="$(start "$RID" python3 "$SB/scripts/poller.py")"
FOREIGN="$(start "other-$$" bash "$SB/bin/chrome-supervisor.sh")"
sleep 0.5
echo "$UNREL"   > "$TD/api-watchdog.pid"
echo "$OBS"     > "$TD/observer.pid"
echo "$POLL"    > "$TD/intake-poller.pid"
echo "$FOREIGN" > "$TD/chrome-supervisor.pid"
out="$( env -u TEAM_DIR TEAM_RUN_ID="$RID" HOME="$SB/home" bash "$PANIC" 2>&1 )"
sleep 0.5; wait "$OBS" "$POLL" 2>/dev/null
printf '%s\n' "$out" | sed 's/^/     | /'
alive "$UNREL"   && ok "api-watchdog pidfile naming an unrelated pid: NOT signalled" || no "unrelated pid survives panic" ""
alive "$FOREIGN" && ok "another run's daemon in our pidfile: NOT signalled" || no "foreign daemon survives panic" ""
alive "$OBS"     && no "observer killed" "" || ok "this run's observer killed"
alive "$POLL"    && no "intake-poller killed" "" || ok "this run's intake-poller killed"
for f in api-watchdog observer intake-poller chrome-supervisor; do
  [ -f "$TD/$f.pid" ] && no "$f.pid removed" "" || ok "$f.pid removed"
done

echo "=== result: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

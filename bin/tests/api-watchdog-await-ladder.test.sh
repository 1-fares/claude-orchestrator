#!/usr/bin/env bash
# A role blocked on an interactive prompt: the api-watchdog tells the ORCHESTRATOR on the
# bus first, then the operator, and repeats at the widening AWAIT_ESC_STEPS gaps while the
# prompt stays open. It never answers the prompt, and never tells the orchestrator about
# itself.
#
# Before: one escalation, to the operator only. The orchestrator, which can often answer
# or re-route without a human, was never told, and a prompt blocked all night produced one
# notice and then silence.
#
# Runs the REAL api-watchdog --once against a stand-in tmux that serves a fixed pane and
# logs every send-keys. Bus lines go to API_WATCHDOG_BUS_SINK and notify decisions to
# NOTIFY_LOG; both name one file, so the order of the two is visible. A stand-in bus
# client covers the real send path (timeout bound, live-team guard). Everything lives
# under one fixed scratch directory, removed on exit; do not run two copies at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/tests/lib/isolate.sh"
rm -rf /tmp/orch-test-api-watchdog-await-ladder
trap 'rm -rf /tmp/orch-test-api-watchdog-await-ladder' EXIT
S=/tmp/orch-test-api-watchdog-await-ladder
TD="$S/team"
mkdir -p "$S/bin" "$TD/health" "$S/sessions"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

cat > "$S/bin/tmux" <<FAKE
#!/usr/bin/env bash
while [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-f" ]; do shift 2; done
cmd="\${1:-}"; shift || true
case "\$cmd" in
  has-session) exit 0 ;;
  list-windows) cat "$S/windows" ;;
  capture-pane) cat "$S/pane" ;;
  send-keys) printf '%s\n' "\$*" >> "$S/sendkeys" ;;
  display-message) echo 1 ;;
  *) : ;;
esac
exit 0
FAKE
# Stand-in bus clients: one records its arguments and environment, one hangs.
cat > "$S/bin/send-ok.py" <<PY
import os, sys
with open("$S/send-args", "a") as f:
    f.write(" ".join(sys.argv[1:]) + " RETRY=" + os.environ.get("BUS_SEND_RETRY_S", "<unset>") + "\n")
PY
printf 'import time\ntime.sleep(30)\n' > "$S/bin/send-hang.py"
chmod +x "$S/bin/tmux"

MENU='● Bash(git push --force origin feature)
  Do you want to proceed?
  ❯ 1. Yes
    2. No, and tell Claude what to do differently
  Enter to select · Esc to cancel'
IDLE='● Done, standing by.
────
❯ '

NOW=$(date +%s)
CASE=0
# setup <role> <pane> <state> <since> [<await-esc file content>]
setup() {
  CASE=$((CASE + 1)); ROLE="$1"
  printf '%s\t%s\n' "@1" "$ROLE" > "$S/windows"
  printf '%s\n' "$2" > "$S/pane"
  printf '{"state":"%s","retries":0,"last_retry_at":0,"since":%s,"last_seen":%s,"fp":"x","fp_since":%s,"nudge_fp":"","nudge_count":0,"last_nudge_at":0}\n' \
    "$3" "$4" "$NOW" "$4" > "$TD/health/$ROLE.json"
  printf '%s' "${5:-}" > "$TD/health/$ROLE.await-esc"
  : > "$S/order.log"; : > "$S/send-args"   # sendkeys accumulates over every case
  AF="$TD/audit/api-watchdog/$ROLE.log"; mkdir -p "$TD/audit/api-watchdog"; : > "$AF"
}
# run_once [VAR=value ...]: one scan; by default the bus line goes to the sink.
run_once() {
  env -u NTFY_URL -u NOTIFY_ACTION_SOURCES -u TEAM_STATUS_HOOK -u API_WATCHDOG_BUS_SEND \
    PATH="$S/bin:$PATH" TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 \
    API_WATCHDOG_BUS_SINK="$S/order.log" \
    NOTIFY_SINK="$S/phone" NOTIFY_LOG="$S/order.log" NOTIFY_STATE_DIR="$S/notify-$CASE" \
    NOTIFY_HOURS=0000-2400 NOTIFY_DAYS=1-7 \
    AWAIT_OPERATOR_SEC=300 AWAIT_ESC_STEPS="1200 3600" WATCHDOG_SESSIONS_DIR="$S/sessions" \
    "$@" timeout 60 bash "$repo/bin/api-watchdog.sh" --once >/dev/null 2>&1 || true
}
state_of() { jq -r '.state // "?"' "$TD/health/$1.json" 2>/dev/null; }
bus_line() { grep -m1 -- '--to orchestrator' "$S/order.log" 2>/dev/null; }
action_line() { grep -m1 -E "(SENT|DEDUPE|QUEUED) action .*role blocked: $ROLE" "$S/order.log" 2>/dev/null; }

. "$repo/bin/lib/watchdog-detect.sh"   # _is_awaiting_input_text, for the quoting check

echo "(a) below AWAIT_OPERATOR_SEC: nothing yet"
setup infra "$MENU" awaiting-input $((NOW - 60))
run_once
[ -z "$(bus_line)" ] && ok "(a) no bus line at 60s" || bad "(a) bus line before the threshold: $(bus_line)"
[ -z "$(action_line)" ] && ok "(a) no operator notice at 60s" || bad "(a) operator notified before the threshold"
[ "$(state_of infra)" = awaiting-input ] && ok "(a) state awaiting-input" || bad "(a) state '$(state_of infra)'"

echo "(b) past the threshold: orchestrator on the bus FIRST, then the operator"
setup infra "$MENU" awaiting-input $((NOW - 400))
run_once
bl="$(bus_line)"
grep -q "role 'infra' has been blocked 6m" <<<"$bl" && ok "(b) the orchestrator is told, with the elapsed time" || bad "(b) no bus line to the orchestrator: '$bl'"
grep -q 'escalation 1' <<<"$bl" && ok "(b) the bus line is escalation 1" || bad "(b) escalation number missing"
[ -n "$(action_line)" ] && ok "(b) the operator is notified (class action)" || bad "(b) no operator action decision: $(cat "$S/order.log")"
first="$(grep -nE -- '--to orchestrator|action .*role blocked' "$S/order.log" | head -1)"
grep -q -- '--to orchestrator' <<<"$first" && ok "(b) bus line precedes the operator notice" || bad "(b) order wrong: $first"
grep -q 'role blocked: infra' "$S/phone" 2>/dev/null && ok "(b) the action reached the notify sink" || bad "(b) nothing in the notify sink"
grep -q 'awaiting-infra.md' <<<"$bl" && ok "(b) the bus line points at the marker" || bad "(b) the bus line does not name the marker"
_is_awaiting_input_text <<<"$bl" && bad "(b) the bus line quotes menu text (would park the orchestrator's own pane)" || ok "(b) the bus line quotes no menu text"
[ "$(state_of infra)" = awaiting-input-esc ] && ok "(b) state awaiting-input-esc" || bad "(b) state '$(state_of infra)'"
grep -q 'escalation 1' "$TD/health/awaiting-infra.md" 2>/dev/null && ok "(b) marker written for escalation 1" || bad "(b) marker missing or unnumbered"
read -r n _ < "$TD/health/infra.await-esc"; [ "$n" = 1 ] && ok "(b) escalation count 1 recorded" || bad "(b) escalation count '$n'"

echo "(c) re-escalation once the first widened gap (1200s) has passed"
setup infra "$MENU" awaiting-input-esc $((NOW - 1800)) "1 $((NOW - 1300))"
run_once
bl="$(bus_line)"
grep -q 'escalation 2' <<<"$bl" && ok "(c) escalation 2 sent to the orchestrator" || bad "(c) no re-escalation: '$bl'"
grep -q 'blocked 30m' <<<"$bl" && ok "(c) it carries the longer elapsed time" || bad "(c) elapsed time not updated"
[ -n "$(action_line)" ] && ok "(c) the operator notice repeats (notify.sh decides delivery)" || bad "(c) no operator decision on escalation 2"
grep -q 'blocked 30m (escalation 2)' "$TD/health/awaiting-infra.md" 2>/dev/null && ok "(c) marker rewritten with the current elapsed time" || bad "(c) marker not rewritten"

echo "(d) inside the widened gap: nothing"
setup infra "$MENU" awaiting-input-esc $((NOW - 1800)) "1 $((NOW - 600))"
run_once
[ -z "$(bus_line)" ] && [ -z "$(action_line)" ] && ok "(d) no escalation 600s after escalation 1 (gap 1200s)" || bad "(d) escalated inside the gap"
[ "$(state_of infra)" = awaiting-input-esc ] && ok "(d) state held at awaiting-input-esc" || bad "(d) state '$(state_of infra)'"

echo "(e) the last gap (3600s) holds past the end of AWAIT_ESC_STEPS"
setup infra "$MENU" awaiting-input-esc $((NOW - 6000)) "2 $((NOW - 3700))"
run_once
grep -q 'escalation 3' <<<"$(bus_line)" && ok "(e) escalation 3 after 3600s" || bad "(e) no escalation 3"
setup infra "$MENU" awaiting-input-esc $((NOW - 9000)) "3 $((NOW - 3700))"
run_once
grep -q 'escalation 4' <<<"$(bus_line)" && ok "(e) escalation 4 on the held 3600s gap" || bad "(e) no escalation 4"
setup infra "$MENU" awaiting-input-esc $((NOW - 9000)) "3 $((NOW - 2000))"
run_once
[ -z "$(bus_line)" ] && ok "(e) not before the held gap (2000s < 3600s)" || bad "(e) escalated early on the held gap"

echo "(f) the orchestrator itself is blocked: no bus line about itself, operator notified"
setup orchestrator "$MENU" awaiting-input $((NOW - 400))
run_once
[ -z "$(bus_line)" ] && ok "(f) the orchestrator is not told about itself" || bad "(f) bus line about the orchestrator: $(bus_line)"
[ -n "$(action_line)" ] && ok "(f) the operator is notified" || bad "(f) no operator notice for a blocked orchestrator"

echo "(g) the prompt clears: count reset, marker removed"
setup infra "$IDLE" awaiting-input-esc $((NOW - 9000)) "3 $((NOW - 100))"
: > "$TD/health/awaiting-infra.md"
run_once
[ ! -s "$TD/health/infra.await-esc" ] && ok "(g) escalation count reset" || bad "(g) count kept: $(cat "$TD/health/infra.await-esc")"
[ ! -e "$TD/health/awaiting-infra.md" ] && ok "(g) marker removed" || bad "(g) marker kept"
grep -q 'RECOVERED-AWAIT' "$AF" && ok "(g) recovery logged" || bad "(g) no RECOVERED-AWAIT line"

echo "(h) a new blocked prompt does not inherit a stale count"
setup infra "$MENU" active $((NOW - 100000)) "3 $((NOW - 100000))"
run_once
[ -z "$(bus_line)" ] && ok "(h) no escalation on first sight of a new prompt" || bad "(h) escalated at once from a stale count: $(bus_line)"
[ ! -s "$TD/health/infra.await-esc" ] && ok "(h) stale count cleared on entry" || bad "(h) stale count kept"

echo "(i) the real send path: live-team guard, bounded by API_WATCHDOG_BUS_TIMEOUT"
setup infra "$MENU" awaiting-input $((NOW - 400))
run_once API_WATCHDOG_BUS_SINK= API_WATCHDOG_BUS_SEND="$S/bin/send-ok.py"
grep -q 'not sent.*no state.md' "$AF" && ok "(i) no state.md: not sent, and logged" || bad "(i) guard line missing: $(tail -2 "$AF")"
[ ! -s "$S/send-args" ] && ok "(i) the bus client is not run without state.md" || bad "(i) bus client ran on a fixture TEAM_DIR"
: > "$TD/state.md"
setup infra "$MENU" awaiting-input $((NOW - 400))
run_once API_WATCHDOG_BUS_SINK= API_WATCHDOG_BUS_SEND="$S/bin/send-ok.py"
grep -q 'orchestrator told on the bus' "$AF" && ok "(i) delivery logged" || bad "(i) no delivery line: $(tail -2 "$AF")"
grep -q -- '--name api-watchdog --to orchestrator' "$S/send-args" && ok "(i) sent as api-watchdog to orchestrator" || bad "(i) args: $(cat "$S/send-args")"
grep -q 'RETRY=0' "$S/send-args" && ok "(i) no bus-send retry inside the scan" || bad "(i) BUS_SEND_RETRY_S not 0"
setup infra "$MENU" awaiting-input $((NOW - 400))
t0=$(date +%s)
run_once API_WATCHDOG_BUS_SINK= API_WATCHDOG_BUS_SEND="$S/bin/send-hang.py" API_WATCHDOG_BUS_TIMEOUT=2
dt=$(( $(date +%s) - t0 ))
[ "$dt" -lt 20 ] && ok "(i) a hanging bus client is cut off (scan took ${dt}s)" || bad "(i) scan took ${dt}s with a hanging bus client"
grep -q 'bus-send FAILED, the orchestrator was NOT told' "$AF" && ok "(i) the failed send is logged" || bad "(i) no failure line: $(tail -2 "$AF")"
[ -n "$(action_line)" ] && ok "(i) the operator is still notified after a failed send" || bad "(i) no operator notice after a failed send"

echo "never answers the prompt"
[ ! -s "$S/sendkeys" ] && ok "no keys sent to any pane in any case" || bad "keys sent: $(tr '\n' ';' < "$S/sendkeys")"

echo
if [ "$fail" = 0 ]; then echo "api-watchdog-await-ladder.test: PASS"; exit 0
else echo "api-watchdog-await-ladder.test: FAIL"; exit 1; fi

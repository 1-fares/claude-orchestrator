#!/usr/bin/env bash
# disk-tmp-watchdog-bus.test.sh: a band change of bin/disk-tmp-watchdog.sh reaches the orchestrator.
# WARN is notify class info (a digest line), so before this the change reached nobody in the team. Each
# change now also sends ONE bus message through bin/bus-send.py, under `timeout`, stdin from /dev/null,
# with a failed send logged and ignored.
# Driven through the DTW_TEST hook (functions only: no lock, pidfile, trap or loop). In memory: log() and
# notify() are replaced by recorders after sourcing and the bus command is `true`, `false`, a missing path
# or a recording function, so the test writes no file and reaches no bus.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DTW="$repo/bin/disk-tmp-watchdog.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

export NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null DTW_LOG=/dev/null TEAM_RUN_ID=rTEST
unset DTW_BUS_SEND DTW_BUS_TO DTW_BUS_TIMEOUT
# shellcheck disable=SC1090
DTW_TEST=1 . "$DTW" || { echo "  FAIL sourcing disk-tmp-watchdog.sh under DTW_TEST"; exit 1; }
for fn in bus_send band_change_notify band_for; do
  declare -F "$fn" >/dev/null && ok "DTW_TEST exposes $fn" || no "DTW_TEST exposes $fn"
done
[ "$DTW_BUS_SEND" = "$repo/bin/bus-send.py" ] && ok "default bus command is bin/bus-send.py" || no "default bus command" "$DTW_BUS_SEND"
[ "$DTW_BUS_TO" = orchestrator ] && ok "default recipient is the orchestrator" || no "default recipient" "$DTW_BUS_TO"

LOGS=(); NOTES=()
log() { LOGS+=("$*"); }
notify() { NOTES+=("$1"); }

echo "== a delivered message logs nothing"
DTW_BUS_SEND=true
band_change_notify "🟠 [disk-tmp/rTEST] WARN: / 86% used, /tmp 10% used."
[ "${#NOTES[@]}" -eq 1 ] && ok "the phone notification still fires once" || no "notify count" "${#NOTES[*]}"
[ "${#LOGS[@]}" -eq 0 ] && ok "no failure line for a delivered message" || no "unexpected log" "${LOGS[*]}"

echo "== a failed send is logged and ignored"
LOGS=(); NOTES=(); DTW_BUS_SEND=false
band_change_notify "🔴 [disk-tmp/rTEST] FREEZE: / 96% used, /tmp 10% used."; rc=$?
[ "$rc" -eq 0 ] && ok "band_change_notify returns 0 although the send failed" || no "rc" "$rc"
[ "${#LOGS[@]}" -eq 1 ] && [[ "${LOGS[0]}" == "bus send to orchestrator failed (rc=1)"* ]] \
  && ok "one failure line: ${LOGS[0]}" || no "failure line" "${LOGS[*]}"
LOGS=(); DTW_BUS_SEND=/nonexistent/bus-send.py
bus_send "status: x"
[ "${#LOGS[@]}" -eq 1 ] && [[ "${LOGS[0]}" == *"rc=127"* ]] && ok "a missing sender is logged with its rc: ${LOGS[0]}" \
  || no "missing sender" "${LOGS[*]}"

echo "== addressing, bound and stdin (timeout replaced by a recorder that fails on purpose)"
# bus_send runs timeout inside a command substitution, so the recorder reports through stderr, which
# bus_send quotes in its failure line.
timeout() { printf 'ARGS=%s STDIN=%s RETRY=%s\n' "$*" "$(readlink "/proc/$BASHPID/fd/0")" "${BUS_SEND_RETRY_S:-unset}" >&2; return 3; }
LOGS=(); DTW_BUS_SEND=/path/to/bus-send.py DTW_BUS_TIMEOUT=7
band_change_notify "🟢 [disk-tmp/rTEST] CLEAR: / 10% / /tmp 10%; heavy work allowed again."
unset -f timeout
line="${LOGS[0]:-}"
[[ "$line" == *"ARGS=7 /path/to/bus-send.py --name disk-tmp-watchdog --to orchestrator --text status: 🟢 [disk-tmp/rTEST] CLEAR:"* ]] \
  && ok "sent as: timeout DTW_BUS_TIMEOUT <sender> --name disk-tmp-watchdog --to orchestrator --text 'status: <notify text>'" \
  || no "argv" "$line"
[[ "$line" == *"STDIN=/dev/null"* ]] && ok "stdin is /dev/null" || no "stdin" "$line"
[[ "$line" == *"RETRY=0"* ]] && ok "BUS_SEND_RETRY_S=0 (the timeout would cut a retry)" || no "retry" "$line"
timeout() { return 124; }
LOGS=(); bus_send "status: x"
unset -f timeout
[[ "${LOGS[0]:-}" == *"rc=124: timed out after 7s"* ]] && ok "an expired timeout is named: ${LOGS[0]}" || no "timeout line" "${LOGS[*]}"

echo "== the main loop delivers every band change through band_change_notify"
n="$(grep -cE 'band_change_notify "(🔴|🟠|🟢) \[disk-tmp/' "$DTW")"
[ "$n" -eq 3 ] && ok "FREEZE, WARN and CLEAR call band_change_notify (3 sites)" || no "call sites" "n=$n"
n="$(grep -cE '^[[:space:]]*(\[ -n "\$cur_band" \] && )?notify "' "$DTW")"
[ "$n" -eq 1 ] && ok "notify is called directly only inside band_change_notify" || no "direct notify calls" "n=$n"

echo
echo "disk-tmp-watchdog-bus: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]

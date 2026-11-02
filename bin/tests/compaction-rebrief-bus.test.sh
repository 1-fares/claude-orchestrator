#!/usr/bin/env bash
# compaction-watchdog: the orchestrator's auto-recovery brief (after a /clear) rejoins the bus with
# bin/bus-inbox.py, not `/is c` (a Monitor on client.py). Runs do_clear_rebrief against a fake tmux that
# records every send-keys; no live pane, no bus.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
TD="$(mktemp -d)"; FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$TD" "$FAKEBIN"' EXIT
mkdir -p "$TD/models" "$TD/health"
export NOTIFY_SINK="$TD/notify-sink" WATCH_ALERT_SINK="$TD/watch-sink"
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
cmd="${1:-}"; shift || true
case "$cmd" in
  send-keys) printf '%s\n' "$*" >> "$FAKE_TD/keys" ;;
  capture-pane) printf '%s\n' "❯ " ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"
env PATH="$FAKEBIN:$PATH" FAKE_TD="$TD" TEAM_DIR="$TD" TEAM_RUN_ID=testrun COMPACT_TEST_SOURCE=1 \
  COMPACT_SOCKET=no-such-socket-compaction-test COMPACT_SESSION=orch-sess \
  COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" COMPACT_HEALTH_DIR="$TD/health" \
  bash -c '. "$0" >/dev/null 2>&1; sleep() { :; }; do_clear_rebrief orch-sess:0' "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1
k="$(cat "$TD/keys" 2>/dev/null)"
/usr/bin/grep -q -- '-l /clear' <<<"$k" && ok "a /clear was typed (the harness ran)" || no "no /clear typed" "$k"
/usr/bin/grep -q "bin/bus-inbox.py status orchestrator" <<<"$k" && ok "the brief checks bus-inbox status" || no "no bus-inbox status in the brief" "$k"
/usr/bin/grep -q "bin/bus-inbox.py wait orchestrator 7200" <<<"$k" && ok "the brief names the wait command" || no "no wait command in the brief" "$k"
/usr/bin/grep -q "Re-join the bus: /is c orchestrator" <<<"$k" && no "the brief still says /is c orchestrator" || ok "the brief no longer says /is c orchestrator"
echo "compaction-rebrief-bus: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

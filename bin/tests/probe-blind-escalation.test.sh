#!/usr/bin/env bash
# Regression test for compaction-watchdog.sh probe-blind escalation.
#
# Guards a live-run finding: a worker's /context probe returned empty 10
# consecutive times (a large context whose /context total overflows the pane
# viewport in fullscreen TUI mode is unreachable via capture-pane). The watchdog
# cannot read that pane, so it MUST escalate — raise the per-role probe-blind
# marker — after PROBE_FAIL_ALARM consecutive failures (default 3).
#
# This runs the REAL watchdog against a fake `tmux` that returns an idle, not-busy
# pane whose /context has no parseable total, and asserts the marker is raised at
# exactly 3 consecutive failures. No live tmux/team needed.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$TD" "$FAKEBIN"' EXIT
mkdir -p "$TD/models" "$TD/health"
echo fable > "$TD/models/testrole"   # a watched (fable) worker

# Fake tmux: idle pane, not busy, empty input, /context with NO parseable total
# (mimics a large-context fullscreen-TUI pane). Same output every call -> stable
# fingerprint -> the idle gate passes and the probe runs.
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
cmd="${1:-}"; shift || true
case "$cmd" in
  has-session) exit 0 ;;
  list-sessions) echo "orch-sess" ;;
  list-windows) echo "1 testrole" ;;
  capture-pane)
    cat <<'PANE'
  Skills - /skills
  /context all to expand
  Bash results using 170k tokens (17%)
--------------------------------------------------------------------------------
>
--------------------------------------------------------------------------------
  -- INSERT -- bypass permissions on - 1 monitor
PANE
    ;;
  send-keys) : ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

PATH="$FAKEBIN:$PATH" TEAM_DIR="$TD" TEAM_RUN_ID=testrun \
  COMPACT_SOCKET=x COMPACT_SESSION=orch-sess \
  COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" \
  COMPACT_HEALTH_DIR="$TD/health" \
  COMPACT_CHECK_INTERVAL=1 COMPACT_IDLE_SEC=0 COMPACT_PROBE_WAIT=0 \
  COMPACT_PROBE_FAIL_ALARM=3 NTFY_URL='' \
  timeout 18 bash "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 || true

marker="$TD/health/compaction-probe-blind-testrole.md"
fail=0
if [ -f "$marker" ]; then echo "PASS: probe-blind marker raised for the worker"; else echo "FAIL: no probe-blind marker raised"; fail=1; fi
if grep -q '3 consecutive' "$marker" 2>/dev/null; then echo "PASS: escalated at the 3rd consecutive failure"; else echo "FAIL: marker did not cite 3 consecutive"; fail=1; fi
if grep -q '\[testrole\] PROBE-BLIND: 3 consecutive' "$TD/log" 2>/dev/null; then echo "PASS: log shows PROBE-BLIND at 3"; else echo "FAIL: log missing the PROBE-BLIND-at-3 line"; echo "--- log tail ---"; tail -25 "$TD/log" 2>/dev/null; fail=1; fi

if [ "$fail" -eq 0 ]; then echo "probe-blind-escalation: ALL PASS"; else echo "probe-blind-escalation: FAILED"; fi
exit "$fail"

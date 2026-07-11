#!/usr/bin/env bash
# Regression test for compaction-watchdog.sh: the ceiling guard covers EVERY
# window, not just probe targets.
#
# Guards a live-run finding (2026-07-11): a default-model worker (no
# $TEAM_DIR/models/<role> fable entry) slipped past both compaction thresholds
# mid-turn and landed on the terminal "Compaction failed" state — and nothing
# escalated, because only window 0 + fable roles were enumerated as targets.
# The fix enumerates every window with a probeflag: ceiling-guard-only targets
# get the passive capture+grep scan, the marker, and the orchestrator
# retire+respawn escalation, but never the keystroke-typing /context probe.
#
# Runs the REAL watchdog against a fake `tmux` with two windows: a healthy
# orchestrator (window 0, probed) and a default-model worker (window 1) wedged
# at compact-failed. No live tmux/team needed.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$TD" "$FAKEBIN"' EXIT
mkdir -p "$TD/models" "$TD/health"
# Deliberately NO models/plainrole entry: default model => ceiling-guard-only.

# Fake tmux: window 1 (plainrole) shows the terminal compact-failed state;
# everything else (window 0, the orchestrator) is a healthy idle pane whose
# /context parses fine.
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
cmd="${1:-}"; shift || true
target=""
prev=""
for a in "$@"; do
  [ "$prev" = "-t" ] && target="$a"
  prev="$a"
done
case "$cmd" in
  has-session) exit 0 ;;
  list-sessions) echo "orch-sess" ;;
  list-windows) printf '0 orchestrator\n1 plainrole\n' ;;
  capture-pane)
    case "$target" in
      *:1)
        printf '%s\n' '⎿  Error: Compaction failed · conversation could not be reduced below the context limit' '❯ '
        ;;
      *)
        printf '%s\n' '● standing by.' '8% context used · /model opus[1m]' '❯ '
        ;;
    esac ;;
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
  COMPACT_RECOVER_DEBOUNCE=0 NTFY_URL='' \
  timeout 15 bash "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 || true

fail=0
marker="$TD/health/ceiling-plainrole.md"
if [ -f "$marker" ]; then echo "PASS: ceiling marker raised for the default-model worker"; else echo "FAIL: no ceiling marker for plainrole"; fail=1; fi
if grep -q '\[plainrole\] CEILING-WEDGE' "$TD/log" 2>/dev/null; then echo "PASS: worker escalated to the orchestrator (CEILING-WEDGE)"; else echo "FAIL: log missing plainrole CEILING-WEDGE"; fail=1; fi
if grep -q 'compact-failed' "$marker" 2>/dev/null; then echo "PASS: marker cites the compact-failed state"; else echo "FAIL: marker does not cite compact-failed"; fail=1; fi
# The /context probe must NEVER run on a ceiling-only target.
if grep -qE '\[plainrole\] (ok: context|probe:|FORCE:|NUDGE:)' "$TD/log" 2>/dev/null; then echo "FAIL: plainrole was probed despite probeflag=0"; fail=1; else echo "PASS: no /context probe on the ceiling-only target"; fi
# The orchestrator (a probe target) is still probed normally.
if grep -qE '\[orchestrator\] ok: context 8%|canary: probe healthy' "$TD/log" 2>/dev/null; then echo "PASS: orchestrator probe path unaffected"; else echo "FAIL: orchestrator probe path broken"; echo "--- log tail ---"; tail -25 "$TD/log" 2>/dev/null; fail=1; fi
# Start line lists the worker as ceiling-only.
if grep -q 'plainrole(ceiling-only)' "$TD/log" 2>/dev/null; then echo "PASS: start line lists plainrole(ceiling-only)"; else echo "FAIL: start line missing ceiling-only listing"; fail=1; fi

if [ "$fail" -eq 0 ]; then echo "compaction-ceiling-worker: ALL PASS"; else echo "compaction-ceiling-worker: FAILED"; fi
exit "$fail"

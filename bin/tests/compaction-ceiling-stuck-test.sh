#!/usr/bin/env bash
# Regression test for compaction-watchdog.sh: a forced /compact that does not
# clear the near-full warning must, after COMPACT_FORCE_ESCALATE attempts, say
# so ONCE (CEILING-STUCK: ntfy + status hook), and the eventual CEILING-CLEARED
# must report the recovery through the hook and reset the episode.
#
# Guards a live-run finding (2026-09-01, 16:55Z-18:04Z): the orchestrator sat at
# 91% for 66 minutes; the watchdog forced /compact five times at its debounce and
# logged each as routine; nobody was told that the coordinator was not answering,
# and the product owner's questions went unacknowledged for the duration.
#
# Runs the REAL watchdog against a fake `tmux` whose window 0 shows the near-full
# warning until a mode file flips it to healthy. No live tmux/team needed.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$TD" "$FAKEBIN"' EXIT
mkdir -p "$TD/models" "$TD/health" "$TD/reports"
echo warn > "$TD/mode"

cat > "$FAKEBIN/tmux" <<FAKE
#!/usr/bin/env bash
while [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-f" ]; do shift 2; done
cmd="\${1:-}"; shift || true
case "\$cmd" in
  has-session) exit 0 ;;
  list-sessions) echo "orch-sess" ;;
  list-windows) printf '0 orchestrator\n' ;;
  capture-pane)
    if [ "\$(cat "$TD/mode")" = warn ]; then
      printf '%s\n' '● thinking…' 'Context is 91% full, autocompact will trigger at 95%' '❯ '
    elif [ "\$(cat "$TD/mode")" = stale ]; then
      printf '%s\n' '● thinking…' 'Context is 91% full, autocompact will trigger at 95%' '⎿  Not enough messages to compact.' '❯ '
    else
      printf '%s\n' '● standing by.' '8% context used · /model opus[1m]' '❯ '
    fi ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

cat > "$TD/hook.sh" <<'H'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "${TEAM_DIR}/hook-calls"
H
chmod +x "$TD/hook.sh"

PATH="$FAKEBIN:$PATH" TEAM_DIR="$TD" TEAM_RUN_ID=testrun TEAM_STATUS_HOOK="$TD/hook.sh" \
  STATUS_HOOK_DEDUPE_SEC=0 \
  COMPACT_SOCKET=x COMPACT_SESSION=orch-sess \
  COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" \
  COMPACT_HEALTH_DIR="$TD/health" \
  COMPACT_CHECK_INTERVAL=1 COMPACT_IDLE_SEC=0 COMPACT_PROBE_WAIT=0 \
  COMPACT_DEBOUNCE_SEC=0 COMPACT_FORCE_ESCALATE=3 COMPACT_RECOVER_DEBOUNCE=0 NTFY_URL='' \
  timeout 20 bash "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 &
wd=$!
# Let it force at least three compactions on the still-near-full pane, then heal the pane.
sleep 6; echo healthy > "$TD/mode"; sleep 4
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null; wait

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
n_force=$(grep -c 'CEILING-WARN: near-full warning on pane (busy-agnostic); forcing /compact' "$TD/log" 2>/dev/null || echo 0)
[ "$n_force" -ge 3 ] && ok "forced /compact at least 3 times ($n_force)" || bad "expected >=3 forced compactions, got $n_force"
n_stuck=$(grep -c 'CEILING-STUCK' "$TD/log" 2>/dev/null || echo 0)
[ "$n_stuck" = 1 ] && ok "CEILING-STUCK logged exactly once per episode" || bad "CEILING-STUCK count $n_stuck (want 1)"
grep -q '^compact-stuck|orchestrator$' "$TD/hook-calls" 2>/dev/null && ok "status hook told compact-stuck" || bad "hook not called with compact-stuck: $(cat "$TD/hook-calls" 2>/dev/null)"
grep -q 'CEILING-CLEARED: pane healthy again (forced compactions this episode: [0-9]' "$TD/log" && ok "CEILING-CLEARED reports the episode's force count" || bad "CEILING-CLEARED missing or without count"
grep -q '^recovered|orchestrator$' "$TD/hook-calls" 2>/dev/null && ok "status hook told recovered" || bad "hook not called with recovered"
grep -q 'FIRE compact-stuck orchestrator' "$TD/reports/status-hook.log" 2>/dev/null && ok "status-hook.log records the fire" || bad "status-hook.log missing FIRE"

# --- Second episode: the pane shows the near-full banner AND Claude Code's reply
# "Not enough messages to compact". The reply is the verdict: the session is at its
# floor and the banner is stale text. Expect CEILING-STALE and an episode reset,
# never CEILING-STUCK, never a compact-stuck hook call. (Seven false firings on run
# r1780489249, 2-6 Sep 2026, each after one real compaction and three refusals.)
rm -f "$TD/hook-calls" "$TD/log" "$TD/lock" "$TD/pid" "$TD/reports/status-hook.log" "$TD/health/"* 2>/dev/null
echo stale > "$TD/mode"
PATH="$FAKEBIN:$PATH" TEAM_DIR="$TD" TEAM_RUN_ID=testrun TEAM_STATUS_HOOK="$TD/hook.sh" \
  STATUS_HOOK_DEDUPE_SEC=0 \
  COMPACT_SOCKET=x COMPACT_SESSION=orch-sess \
  COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" \
  COMPACT_HEALTH_DIR="$TD/health" \
  COMPACT_CHECK_INTERVAL=1 COMPACT_IDLE_SEC=0 COMPACT_PROBE_WAIT=0 \
  COMPACT_DEBOUNCE_SEC=0 COMPACT_FORCE_ESCALATE=3 COMPACT_RECOVER_DEBOUNCE=0 NTFY_URL='' \
  timeout 20 bash "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 &
wd=$!
sleep 6
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null; wait
n_stale=$(grep -c 'CEILING-STALE' "$TD/log" 2>/dev/null); n_stale=${n_stale:-0}
n_stuck2=$(grep -c 'CEILING-STUCK' "$TD/log" 2>/dev/null); n_stuck2=${n_stuck2:-0}
[ "$n_stale" -ge 1 ] && ok "refused /compact logged as CEILING-STALE ($n_stale)" || bad "no CEILING-STALE on a refused /compact"
[ "$n_stuck2" = 0 ] && ok "no CEILING-STUCK when /compact is refused" || bad "CEILING-STUCK fired $n_stuck2 times on a refused /compact"
grep -q '^compact-stuck|' "$TD/hook-calls" 2>/dev/null && bad "status hook told compact-stuck on a stale banner" || ok "status hook not called on a stale banner"
[ -f "$TD/health/ceiling-orchestrator.md" ] && bad "ceiling marker left behind after CEILING-STALE" || ok "ceiling marker removed on CEILING-STALE"

[ "$fail" = 0 ] && echo "compaction-ceiling-stuck-test: PASS" || { echo "compaction-ceiling-stuck-test: FAIL"; sed -n 1,20p "$TD/log"; exit 1; }

#!/usr/bin/env bash
# Integration test for the api-watchdog API-STALL episode memory, end to end
# against a REAL tmux session on an isolated socket + state dir.
#
# Guards a live-run finding (2026-07-11): a role stalling on the SAME error
# (a content-filter block) never escalated — each "try again" made the pane
# busy for a scan, the busy path reset the health-file retry counter, and the
# re-entry restarted at retry 0. One role looped 7 hours at "retry 1/5".
# The fix: an episode marker file persists the count/backoff across busy blips
# (API_EPISODE_WINDOW_SEC); give-up becomes reachable and hands the error to
# the orchestrator once per episode.
# Run: bin/tests/watchdog-apistall-episode-test.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

. "$repo/bin/tests/lib/isolate.sh"
export API_WATCHDOG_PATTERNS="$repo/bin/api-watchdog.patterns"
export API_BACKOFF_SEC="1 1"
export API_EPISODE_WINDOW_SEC=1800
unset NTFY_URL

. "$repo/bin/team-env.sh"
isolate_assert
TM="$TEAM_TMUX_BIN -L $TEAM_TMUX"
hf="$TEAM_DIR/health"
af="$TEAM_DIR/audit/api-watchdog/apirole.log"

cleanup() {
  $TM kill-server 2>/dev/null || true
  rm -rf "$TEAM_DIR" 2>/dev/null || true
}
trap cleanup EXIT

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
state_of() { jq -r '.state // "?"' "$hf/$1.json" 2>/dev/null || echo "?"; }
field_of() { jq -r --arg k "$2" '.[$k] // "?"' "$hf/$1.json" 2>/dev/null || echo "?"; }
scan() { bash "$repo/bin/api-watchdog.sh" --once --max-retries 2 >/dev/null 2>&1; }
count_audit() { grep -c "$1" "$af" 2>/dev/null || echo 0; }

# The stalled pane: a content-filter block at an idle prompt. stty -echo so the
# watchdog's "try again" keystrokes are not echoed: the pane stays showing the
# error, exercising the retry-loop-on-the-same-error path deterministically.
err_pane() {
  $TM kill-window -t "$TEAM_SESSION:apirole" 2>/dev/null || true
  $TM new-window -t "$TEAM_SESSION" -n apirole \
    "bash -c 'stty -echo 2>/dev/null; printf \"● transcribing the memorandum…\n  ⎿ API Error: 400 Output blocked by content filtering policy\n────\n❯ \n\"; sleep 600'"
  sleep 1
}
# The busy blip between retries: the "try again" turn in flight.
busy_pane() {
  $TM kill-window -t "$TEAM_SESSION:apirole" 2>/dev/null || true
  $TM new-window -t "$TEAM_SESSION" -n apirole \
    "bash -c 'i=0; while true; do printf \"● retrying step %d… esc to interrupt\n\" \$i; i=\$((i+1)); sleep 1; done'"
  sleep 1
}

echo "setting up isolated tmux session $TEAM_SESSION on socket $TEAM_TMUX"
# Window 0 = orchestrator (echo ON so the give-up escalation text is assertable).
$TM new-session -d -s "$TEAM_SESSION" -n orchestrator \
  "bash -c 'printf \"● standing by.\n────\n❯ \n\"; sleep 600'"
sleep 1

echo "step 1: first stall -> stalled-api, retry 1, episode marker written"
err_pane
scan
s1="$(state_of apirole)"; r1="$(field_of apirole retries)"
[ "$s1" = "stalled-api" ] && ok "apirole -> stalled-api" || bad "expected stalled-api, got '$s1'"
[ "$r1" = "1" ] && ok "retry 1 fired immediately" || bad "expected retries=1, got '$r1'"
[ -f "$hf/apirole.api-episode" ] && ok "episode marker written" || bad "episode marker missing"

echo "step 2: retry makes the pane busy -> active (health counters reset: the blip)"
busy_pane
scan
s2="$(state_of apirole)"; r2="$(field_of apirole retries)"
[ "$s2" = "active" ] && ok "apirole busy blip -> active" || bad "expected active, got '$s2'"
[ "$r2" = "0" ] && ok "health-file retries reset by the blip (the pre-fix loop mechanism)" || bad "expected retries=0, got '$r2'"

echo "step 3: same error re-appears -> episode restored, retry 2 (NOT restart at 0)"
err_pane
sleep 1
scan
r3="$(field_of apirole retries)"
grep -q "STALLED again (episode continues at 1 retries)" "$af" 2>/dev/null \
  && ok "audit records episode continuation at 1" || bad "audit missing episode-continuation line"
[ "$r3" = "2" ] && ok "retry 2 fired (count carried across the blip)" || bad "expected retries=2, got '$r3'"
[ "$(count_audit 'STALLED (api/network error)')" = "1" ] \
  && ok "no fresh-episode restart logged" || bad "episode wrongly restarted from 0"

echo "step 4: retries exhausted -> give-up + orchestrator escalation, once"
scan
s4="$(state_of apirole)"
[ "$s4" = "give-up" ] && ok "apirole -> give-up (episode retries exhausted)" || bad "expected give-up, got '$s4'"
grep -q "GIVE-UP after 2 retries" "$af" 2>/dev/null \
  && ok "audit records GIVE-UP" || bad "audit missing GIVE-UP line"
[ -f "$hf/apirole.api-giveup-sent" ] && ok "give-up dedupe marker written" || bad "give-up marker missing"
sleep 1
# tr -d '\n' before grepping: the pane hard-wraps long messages mid-word.
otxt="$($TM capture-pane -t "$TEAM_SESSION:orchestrator" -p 2>/dev/null | tr -d '\n')"
printf '%s' "$otxt" | grep -q "stalled on the same API error" \
  && ok "orchestrator pane received the escalation" || bad "orchestrator pane missing escalation text"
printf '%s' "$otxt" | grep -q "content-filter block" \
  && ok "escalation carries the content-filter ladder hint" || bad "content-filter hint missing"

echo "step 5: still stalled -> give-up holds, no repeat escalation"
scan
[ "$(state_of apirole)" = "give-up" ] && ok "give-up sticky while still stalled" || bad "state churned off give-up"
[ "$(count_audit 'GIVE-UP after')" = "1" ] && ok "GIVE-UP logged exactly once per episode" || bad "GIVE-UP re-logged"
# The escalation text sits on the orchestrator's pane; it must not itself match
# the stall patterns (the raw error line is pointed at, not quoted).
[ "$(state_of orchestrator)" = "active" ] \
  && ok "orchestrator not mis-classified by the escalation text" || bad "orchestrator wrongly '$(state_of orchestrator)'"

echo "step 6: genuine recovery -> markers cleared, next stall is a fresh episode"
$TM kill-window -t "$TEAM_SESSION:apirole" 2>/dev/null || true
$TM new-window -t "$TEAM_SESSION" -n apirole \
  "bash -c 'stty -echo 2>/dev/null; printf \"● Resuming the unit.\n────\n❯ \n\"; sleep 600'"
sleep 1
scan
[ "$(state_of apirole)" = "active" ] && ok "apirole recovered to active" || bad "expected active, got '$(state_of apirole)'"
[ ! -f "$hf/apirole.api-episode" ] && ok "episode marker cleared on recovery" || bad "episode marker not cleared"
[ ! -f "$hf/apirole.api-giveup-sent" ] && ok "give-up marker cleared on recovery" || bad "give-up marker not cleared"

echo "step 7: a role recovering from a usage stall wakes the idle orchestrator"
# The overnight-outage gap (2026-07-10): workers resume their own turns when
# usage returns, but an orchestrator that was idle at the prompt has no turn to
# resume and nothing re-dispatches work. The RECOVERED-USAGE branch must send
# one deduped wake nudge to the orchestrator.
$TM new-window -t "$TEAM_SESSION" -n usagerole \
  "bash -c 'stty -echo 2>/dev/null; printf \"● Drafting.\n  You have reached your usage limit.\n ❯ 1. Stop and wait for limit to reset\n   2. Add funds to continue with usage credits\n Enter to confirm · Esc to cancel\n\"; sleep 600'"
sleep 1
scan
[ "$(state_of usagerole)" = "stalled-usage" ] && ok "usagerole -> stalled-usage" || bad "expected stalled-usage, got '$(state_of usagerole)'"
$TM kill-window -t "$TEAM_SESSION:usagerole" 2>/dev/null || true
$TM new-window -t "$TEAM_SESSION" -n usagerole \
  "bash -c 'stty -echo 2>/dev/null; printf \"● Resuming.\n────\n❯ \n\"; sleep 600'"
sleep 1
scan
[ -f "$hf/orchestrator.usage-wake" ] && ok "usage-wake dedupe marker written" || bad "usage-wake marker missing"
grep -q "USAGE-WAKE sent to orchestrator" "$TEAM_DIR/audit/api-watchdog/usagerole.log" 2>/dev/null \
  && ok "audit records the wake" || bad "audit missing USAGE-WAKE line"
sleep 1
otxt="$($TM capture-pane -t "$TEAM_SESSION:orchestrator" -p 2>/dev/null | tr -d '\n')"
printf '%s' "$otxt" | grep -q "usage outage may be over" \
  && ok "orchestrator pane received the wake nudge" || bad "orchestrator pane missing wake text"

echo
if [ "$fail" = 0 ]; then echo "PASS: api-stall episode memory + give-up escalation + usage wake"; exit 0
else echo "FAIL: see above"; exit 1; fi

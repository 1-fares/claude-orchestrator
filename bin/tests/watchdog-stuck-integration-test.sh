#!/usr/bin/env bash
# Integration test for api-watchdog stuck detection + recovery, end to end
# against a REAL tmux session on an isolated socket + state dir (no contact with
# any live team). Drives the real bin/api-watchdog.sh --once across timed steps
# and asserts the active -> stuck -> stuck-giveup transitions, the interrupt+
# nudge, and that a genuinely-progressing busy role is never flagged.
# Run: bin/tests/watchdog-stuck-integration-test.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Isolated run: own socket + own .team dir under the worktree.
export TEAM_RUN_ID="wdtest$$"
export TEAM_TMUX="wdt$$"
export STUCK_THRESHOLD_SEC=2
export STUCK_MAX_NUDGES=2
export AWAIT_OPERATOR_SEC=2
export API_WATCHDOG_PATTERNS="$repo/bin/api-watchdog.patterns"
unset NTFY_URL

# Resolve derived names without disturbing anything live.
. "$repo/bin/team-env.sh"
TM="$TEAM_TMUX_BIN -L $TEAM_TMUX"
hf="$TEAM_DIR/health"

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
scan() { bash "$repo/bin/api-watchdog.sh" --once >/dev/null 2>&1; }

echo "setting up isolated tmux session $TEAM_SESSION on socket $TEAM_TMUX"
# A wedged role: prints a busy, frozen pane (spinner + a hung tool call), holds.
# stty -echo so the watchdog's interrupt+nudge keystrokes are NOT echoed into
# the pane: it stays genuinely frozen, exercising the "interrupt did nothing ->
# escalate" path deterministically.
$TM new-session -d -s "$TEAM_SESSION" -n stuckrole \
  "bash -c 'stty -echo 2>/dev/null; printf \"● Calling chrome-devtools…\n· Working… (12m 0s · esc to interrupt)\n────\n❯ \n\"; sleep 600'"
# A genuinely-working role: pane content changes every second.
$TM new-window -t "$TEAM_SESSION" -n busyrole \
  "bash -c 'i=0; while true; do printf \"● step %d done, continuing… esc to interrupt\n\" \$i; i=\$((i+1)); sleep 1; done'"
# A long-THINK role: body is STATIC but the token counter climbs each tick.
# Must read as alive via the token readout, never flagged stuck (the
# false-positive case a body-only fingerprint would wrongly trip).
$TM new-window -t "$TEAM_SESSION" -n thinkrole \
  "bash -c 'stty -echo 2>/dev/null; i=340; while true; do clear; printf \"● analyzing screenshot for the alert-hue check…\n· Thinking… (15m 0s · ↓ %d.0k tokens · esc to interrupt)\n────\n❯ \n\" \$i; i=\$((i+1)); sleep 1; done'"
sleep 1

echo "step 1: first scan (content just observed; not yet stuck)"
scan
eq1="$(state_of stuckrole)"
[ "$eq1" = "active" ] && ok "stuckrole active on first sight" || bad "stuckrole expected active, got '$eq1'"

echo "step 2: let it stay frozen past the ${STUCK_THRESHOLD_SEC}s threshold, scan -> stuck + nudge"
sleep 3
scan
s2="$(state_of stuckrole)"; n2="$(field_of stuckrole nudge_count)"
[ "$s2" = "stuck" ] && ok "stuckrole -> stuck" || bad "stuckrole expected stuck, got '$s2'"
[ "$n2" = "1" ] && ok "interrupt+nudge attempted (nudge_count=1)" || bad "expected nudge_count=1, got '$n2'"
grep -q "STUCK " "$TEAM_DIR/audit/api-watchdog/stuckrole.log" 2>/dev/null \
  && ok "audit log records STUCK" || bad "audit log missing STUCK line"

echo "step 3: still frozen on the same content we nudged -> escalate to stuck-giveup"
sleep 1
scan
s3="$(state_of stuckrole)"
[ "$s3" = "stuck-giveup" ] && ok "stuckrole -> stuck-giveup (nudge ineffective)" || bad "expected stuck-giveup, got '$s3'"
grep -q "STUCK-GIVEUP" "$TEAM_DIR/audit/api-watchdog/stuckrole.log" 2>/dev/null \
  && ok "audit log records STUCK-GIVEUP" || bad "audit log missing STUCK-GIVEUP line"

echo "control: a genuinely-progressing busy role is NEVER flagged stuck"
sb="$(state_of busyrole)"
[ "$sb" = "active" ] && ok "busyrole stays active (pane changing each tick)" || bad "busyrole wrongly '$sb'"

echo "control: a long THINK (static body, climbing tokens) is NEVER flagged stuck"
# It has been frozen-bodied well past the threshold by now; token liveness must
# keep it active.
scan
st="$(state_of thinkrole)"
[ "$st" = "active" ] && ok "thinkrole stays active (token readout advancing)" || bad "thinkrole wrongly '$st' (token-liveness regression)"

echo "step 4: a role blocked on an interactive menu -> awaiting-input -> escalate + marker"
# A blocked-on-menu role: prints a selection menu (no spinner) and holds. This
# is the silent stall the api-stall and stuck detectors both miss.
$TM new-window -t "$TEAM_SESSION" -n waitrole \
  "bash -c 'stty -echo 2>/dev/null; printf \"● How should the team proceed?\n❯ 1. Hold steady-state\n  2. Resume the parked workstream\n────\n  Enter to select · up/down to navigate · Esc to cancel\n\"; sleep 600'"
sleep 1
scan
sw1="$(state_of waitrole)"
[ "$sw1" = "awaiting-input" ] && ok "waitrole -> awaiting-input on first sight" || bad "waitrole expected awaiting-input, got '$sw1'"
[ ! -f "$hf/awaiting-waitrole.md" ] && ok "no operator marker before threshold" || bad "marker written too early"
sleep 3
scan
sw2="$(state_of waitrole)"
[ "$sw2" = "awaiting-input-esc" ] && ok "waitrole -> awaiting-input-esc after threshold" || bad "expected awaiting-input-esc, got '$sw2'"
[ -f "$hf/awaiting-waitrole.md" ] && ok "operator marker written" || bad "operator marker missing"
grep -q "AWAITING-INPUT-ESCALATED" "$TEAM_DIR/audit/api-watchdog/waitrole.log" 2>/dev/null \
  && ok "audit log records escalation" || bad "audit log missing escalation line"
# A second scan must NOT re-escalate (state stays -esc, idempotent push).
scan
[ "$(state_of waitrole)" = "awaiting-input-esc" ] && ok "no re-escalation while still blocked" || bad "state churned off awaiting-input-esc"

echo "step 5: prompt clears (operator answered) -> recovery removes the marker"
$TM kill-window -t "$TEAM_SESSION:waitrole" 2>/dev/null || true
$TM new-window -t "$TEAM_SESSION" -n waitrole \
  "bash -c 'stty -echo 2>/dev/null; printf \"● Done, standing by.\n────\n❯ \n\"; sleep 600'"
sleep 1
scan
sw3="$(state_of waitrole)"
[ "$sw3" = "active" ] && ok "waitrole recovered to active" || bad "expected active, got '$sw3'"
[ ! -f "$hf/awaiting-waitrole.md" ] && ok "operator marker removed on recovery" || bad "marker not removed"
grep -q "RECOVERED-AWAIT" "$TEAM_DIR/audit/api-watchdog/waitrole.log" 2>/dev/null \
  && ok "audit log records recovery" || bad "audit log missing recovery line"

echo
if [ "$fail" = 0 ]; then echo "PASS: stuck detection + recovery ladder + awaiting-input escalation"; exit 0
else echo "FAIL: see above"; exit 1; fi

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

echo
if [ "$fail" = 0 ]; then echo "PASS: stuck detection + recovery ladder"; exit 0
else echo "FAIL: see above"; exit 1; fi

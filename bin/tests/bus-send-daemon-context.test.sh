#!/usr/bin/env bash
# Prove bus-send.py works from a daemon/cron-like environment with no Claude
# Code session ancestor, and that send.py still fails in the same environment.
#
# Requires: the inter-session bus server running, at least one listener
# registered (the orchestrator). Runs under `env -i` to strip the process tree.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IS_BIN="$HOME/.claude/skills/is/bin"
BUS_SEND="$repo/bin/bus-send.py"
MSG_LOG="$HOME/.claude/data/inter-session/messages.log"

pass=0 fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

printf 'bus-send-daemon-context: starting\n'

# --- prereqs ---
[ -f "$BUS_SEND" ] || { echo "SKIP: bus-send.py not found at $BUS_SEND"; exit 0; }
[ -f "$IS_BIN/send.py" ] || { echo "SKIP: send.py not found"; exit 0; }
[ -f "$MSG_LOG" ] || { echo "SKIP: messages.log not found (bus never ran?)"; exit 0; }

# Source team-env for the port.
INTER_SESSION_PORT="${INTER_SESSION_PORT:-}"
if [ -z "$INTER_SESSION_PORT" ] && [ -f "$repo/bin/team-env.sh" ]; then
  INTER_SESSION_PORT="$(. "$repo/bin/team-env.sh" 2>/dev/null; echo "$INTER_SESSION_PORT")" || true
fi
[ -n "$INTER_SESSION_PORT" ] || { echo "SKIP: cannot determine INTER_SESSION_PORT"; exit 0; }

daemon_name="test-daemon-$$"
marker="bus-send-test-$(date +%s)-$$"

# --- 1. NEGATIVE CONTROL: send.py must fail from cron-like env ---
# Run with init as the only ancestor (no Claude Code session in the tree).
# env -i strips the env; we re-inject only what's needed.
send_rc=0
env -i HOME="$HOME" PATH="$PATH" INTER_SESSION_PORT="$INTER_SESSION_PORT" \
  python3 "$IS_BIN/send.py" --to orchestrator --text "negative-control-$marker" \
  >/dev/null 2>/dev/null || send_rc=$?
[ "$send_rc" -ne 0 ] \
  && ok "send.py fails from cron-like env (exit $send_rc)" \
  || no "send.py should fail from cron-like env but exited 0"

# --- 2. POSITIVE: bus-send.py must succeed from the same env ---
bus_rc=0
env -i HOME="$HOME" PATH="$PATH" INTER_SESSION_PORT="$INTER_SESSION_PORT" \
  python3 "$BUS_SEND" --name "$daemon_name" --to orchestrator --text "$marker" \
  >/dev/null 2>/dev/null || bus_rc=$?
[ "$bus_rc" -eq 0 ] \
  && ok "bus-send.py succeeds from cron-like env" \
  || no "bus-send.py failed from cron-like env (exit $bus_rc)"

# --- 3. VERIFY: messages.log holds a row with from_name == daemon_name ---
sleep 0.5
if grep -q "\"from_name\":\"$daemon_name\"" "$MSG_LOG" 2>/dev/null ||
   grep -q "\"from_name\": \"$daemon_name\"" "$MSG_LOG" 2>/dev/null; then
  ok "messages.log has from_name=$daemon_name"
else
  # The log format might use a different field name; check for the marker text.
  if grep -q "$marker" "$MSG_LOG" 2>/dev/null; then
    ok "messages.log has the marker text (from_name format may differ)"
  else
    no "messages.log has no row matching daemon_name=$daemon_name or marker=$marker"
  fi
fi

# --- 4. VERIFY: negative control's message is NOT in the log ---
if grep -q "negative-control-$marker" "$MSG_LOG" 2>/dev/null; then
  no "negative control's message should NOT be in messages.log"
else
  ok "negative control's message correctly absent from messages.log"
fi

printf '\nbus-send-daemon-context: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

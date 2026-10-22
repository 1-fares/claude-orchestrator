#!/usr/bin/env bash
# Prove bus-send.py works from a daemon/cron-like environment with no Claude
# Code session ancestor, and that send.py still fails in the same environment.
#
# Requires: the inter-session bus server running. The suite registers its OWN throwaway sink
# and sends only to it -- never to a real role. Runs under `env -i` to strip the process tree.
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
LIVE_MSG_LOG="$MSG_LOG"   # read ONLY, to prove nothing reached the live bus (check 6)

daemon_name="test-daemon-$$"
marker="bus-send-test-$(date +%s)-$$"

# A PRIVATE BUS, NEVER THE LIVE ONE. send.py/bus-send.py are the subject, so every call runs the
# real interpreter against a bus of its own: private INTER_SESSION_DATA_DIR (token, listener
# state, messages.log) and a free port, brought up by a client.py peer that is also the sink.
# Sending on the team port would deliver test traffic to live roles.
W="$(mktemp -d)"; PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')"
export INTER_SESSION_DATA_DIR="$W/data" INTER_SESSION_PORT="$PORT"; mkdir -p "$W/data"
MSG_LOG="$W/data/messages.log"
SINK="bus-send-test-sink-$$"; _SINKOUT="$W/sink.out"
INTER_SESSION_PPID_OVERRIDE=100031 "python3" "$IS_BIN/client.py" --name "$SINK" >"$_SINKOUT" 2>&1 &
_SINKPID=$!
for _i in $(seq 1 60); do
  grep -q "^$SINK" <<<"$(INTER_SESSION_PPID_OVERRIDE=100031 "python3" "$IS_BIN/list.py" 2>/dev/null)" && break; sleep 0.25
done
grep -q "^$SINK" <<<"$(INTER_SESSION_PPID_OVERRIDE=100031 "python3" "$IS_BIN/list.py" 2>/dev/null)" \
  && ok "PRECONDITION: a throwaway sink ($SINK) is up on a PRIVATE bus (port $PORT, data $W/data), off the live bus" \
  || { no "PRECONDITION: the private bus/sink did not come up ($(head -2 "$_SINKOUT" | tr '\n' ' ')) -- refusing to send anywhere"; kill "$_SINKPID" 2>/dev/null; rm -rf "$W"; exit 1; }
[ "$(realpath -m "$INTER_SESSION_DATA_DIR")" != "$(realpath -m "$HOME/.claude/data/inter-session")" ] \
  && ok "PRECONDITION: the data dir is not the live one" || { no "data dir IS the live one -- refusing"; exit 1; }

# --- 1. NEGATIVE CONTROL: send.py must fail from cron-like env ---
# `env -i` STRIPS THE ENVIRONMENT, NOT THE PROCESS TREE, and the guard keys on the tree: send.py's
# listener discovery walks the ppid chain, so from inside a session `env -i` still finds that
# session's state and send.py SENDS. Detach the ancestry first, and check that it really is
# detached, or the row tests nothing.
_RCF="$(mktemp)"; _OUTF="$(mktemp)"; _WRAP="$(mktemp)"
trap 'rm -f "$_RCF" "$_OUTF" "$_WRAP"; kill "$_SINKPID" 2>/dev/null; [ -f "$W/data/server.$PORT.pid" ] && kill "$(cat "$W/data/server.$PORT.pid")" 2>/dev/null; rm -rf "$W"' EXIT
printf '%s\n' '#!/bin/sh' '"$@" > "$OUTF" 2>&1' 'echo $? > "$RCF"' > "$_WRAP"

# `setsid --wait` keeps the waiting parent in the chain and plain `setsid` forks only when the
# caller is already a group leader; `setsid --fork` always detaches (ppid=1). The parent cannot
# wait for it, so the exit code comes back through a file.
_detach_run() {
  : > "$_RCF"; : > "$_OUTF"
  setsid --fork env -i HOME="$HOME" PATH="$PATH" INTER_SESSION_PORT="$INTER_SESSION_PORT" INTER_SESSION_DATA_DIR="$INTER_SESSION_DATA_DIR" \
    OUTF="$_OUTF" RCF="$_RCF" \
    sh "$_WRAP" "$@" </dev/null >/dev/null 2>&1 &
  local i
  for i in $(seq 1 150); do [ -s "$_RCF" ] && return 0; sleep 0.2; done
  return 1
}

_detach_run "python3" -c 'import sys; sys.path.insert(0, sys.argv[1]); from bin import discover; s, _ = discover.find_listener_state_with_path(); print("STATE_FOUND" if s else "NO_STATE")' "$(cd "$IS_BIN/.." && pwd)" || true
detached_state="$(tail -1 "$_OUTF" 2>/dev/null)"
[ "$detached_state" = "NO_STATE" ] \
  && ok "PRECONDITION: setsid really detaches the ancestry (no listener state visible)" \
  || no "PRECONDITION: ancestry not detached (got '$detached_state') -- the row below tests nothing and would SEND"

send_rc=0
if [ "$detached_state" = "NO_STATE" ]; then
  _detach_run "python3" "$IS_BIN/send.py" \
    --to "$SINK" --text "negative-control-$marker" || true
  send_rc="$(cat "$_RCF" 2>/dev/null || echo 0)"
  [ "$send_rc" -ne 0 ] \
    && ok "send.py fails with no Claude Code session in the tree (exit $send_rc)" \
    || no "send.py should fail with no session ancestor but exited 0"
else
  no "SKIPPED the send.py negative control: refusing to send a live message under an unreproduced precondition"
fi

# --- 2. POSITIVE: bus-send.py must succeed from the same env ---
bus_rc=0
env -i HOME="$HOME" PATH="$PATH" INTER_SESSION_PORT="$INTER_SESSION_PORT" INTER_SESSION_DATA_DIR="$INTER_SESSION_DATA_DIR" \
  "python3" "$BUS_SEND" --name "$daemon_name" --to "$SINK" --text "$marker" \
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

# --- 5. VERIFY AT THE RECEIVER: the sink got the daemon's message, and only that one ---
sleep 0.5
grep -q "$marker" "$_SINKOUT" && ! grep -q "negative-control-$marker" "$_SINKOUT" \
  && ok "the SINK received the bus-send marker, and not the negative control's message" \
  || no "sink contents wrong: $(grep -c . "$_SINKOUT") line(s); marker=$(grep -c "$marker" "$_SINKOUT") negative=$(grep -c "negative-control" "$_SINKOUT")"
grep -q "\"from_name\": *\"$daemon_name" "$_SINKOUT" || grep -q "$daemon_name" "$_SINKOUT" \
  && ok "and the message came from the daemon name ($daemon_name)" \
  || no "the sink's message does not carry the daemon name"

# --- 6. ISOLATION: nothing from this run reached the LIVE bus's log ---
if [ -f "$LIVE_MSG_LOG" ] && grep -q "$marker" "$LIVE_MSG_LOG" 2>/dev/null; then
  no "the marker reached the LIVE messages.log -- this suite is on the live bus again"
else
  ok "the live messages.log has no row from this run (private bus held)"
fi

printf '\nbus-send-daemon-context: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

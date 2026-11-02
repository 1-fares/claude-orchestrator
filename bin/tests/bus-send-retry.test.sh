#!/usr/bin/env bash
# bus-send.py's retry of a refusal for an ABSENT name. PRIVATE BUS ONLY (own INTER_SESSION_DATA_DIR + free
# port, brought up by a throwaway sink peer, as bus-send-daemon-context.test.sh does).
# BUS_SEND_PY overrides the bus-send under test (red-first runs).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY=python3
VPY="$HOME/.claude/data/inter-session/venv/bin/python"; [ -x "$VPY" ] || VPY=python3
IS_BIN="$HOME/.claude/skills/is/bin"
BS="${BUS_SEND_PY:-$repo/bin/bus-send.py}"
pass=0 fail=0
ok() { printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
printf 'bus-send-retry: starting\n'

W="$(mktemp -d)"; PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')"
export INTER_SESSION_DATA_DIR="$W/data" INTER_SESSION_PORT="$PORT" NOTIFY_SINK="$W/notify.sink" WATCH_ALERT_SINK="$W/watch.sink"
unset TEAM_PORT TEAM_RUN_ID TEAM_DIR BUS_SEND_RETRY_S
mkdir -p "$W/data"
SINK="bsr-sink-$$"; SINKKEY=100032
INTER_SESSION_PPID_OVERRIDE=$SINKKEY "$PY" "$IS_BIN/client.py" --name "$SINK" > "$W/sink.out" 2>&1 & SINKPID=$!
LATE=""
cleanup() { kill "$SINKPID" 2>/dev/null; [ -n "$LATE" ] && kill "$LATE" 2>/dev/null
  [ -f "$W/data/server.$PORT.pid" ] && kill "$(head -1 "$W/data/server.$PORT.pid" | tr -dc 0-9)" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
# names on the private bus, as seen by the sink's own session
onbus() { local l; l="$(INTER_SESSION_PPID_OVERRIDE=$SINKKEY "$PY" "$IS_BIN/list.py" 2>/dev/null | awk 'NR>1 {print $1}')"
  /usr/bin/grep -qx -- "$1" <<<"$l"; }
for i in $(seq 1 60); do onbus "$SINK" && break; sleep 0.25; done
onbus "$SINK" && [ "$(realpath -m "$W/data")" != "$(realpath -m "$HOME/.claude/data/inter-session")" ] \
  && ok "PRECONDITION: private bus on port $PORT with sink $SINK" || { no "PRECONDITION: private bus did not come up"; exit 1; }
send() { BUS_SEND_NAME=bsr "$PY" "$BS" --name bsr --to "$1" --text "$2"; }

# 1 strict parsing: unset = 30; empty / off / nan / negative / 0 = 0 (off); clamped to 60 (inf included)
parse() { env ${1+BUS_SEND_RETRY_S="$1"} INTER_SESSION_NO_REEXEC=1 PYTHONDONTWRITEBYTECODE=1 "$VPY" - "$BS" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); print(m._RETRY_S)
PYEOF
} 2>/dev/null
got="unset=$(parse) empty=$(parse '') off=$(parse off) nan=$(parse nan) neg=$(parse -5) zero=$(parse 0) six=$(parse 6) hundred=$(parse 100) inf=$(parse inf)"
[ "$got" = "unset=30.0 empty=0.0 off=0.0 nan=0.0 neg=0.0 zero=0.0 six=6.0 hundred=60.0 inf=60.0" ] \
  && ok "1 parse: $got" || no "1 parse: $got"

# 2 retry off: an absent name is refused at once, with the same last line as before
t=$(date +%s); out="$(BUS_SEND_RETRY_S=0 send "bsr-absent-$$" x 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
last="$(printf '%s\n' "$out" | tail -1)"
[ $rc -eq 1 ] && [ $dt -le 5 ] && [ "${last#send error: unknown_peer: no agent matches}" != "$last" ] \
  && ok "2 retry off: rc 1 in ${dt}s, last line '${last:0:45}'" || no "2 rc=$rc dt=$dt: $out"

# 3 a name that stays absent: held about BUS_SEND_RETRY_S, then rc 1 and that same last line, once
t=$(date +%s); out="$(BUS_SEND_RETRY_S=6 send "bsr-absent-$$" x 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
last="$(printf '%s\n' "$out" | tail -1)"
[ $rc -eq 1 ] && [ $dt -ge 3 ] && [ $dt -le 12 ] && [ "${last#send error: unknown_peer: no agent matches}" != "$last" ] \
  && [ "$(printf '%s\n' "$out" | /usr/bin/grep -c 'send error')" -eq 1 ] \
  && ok "3 absent through the retry: rc 1 after ${dt}s, one error line" || no "3 rc=$rc dt=$dt: $out"

# 4 a name that comes onto the bus during the retry: delivered
LN="bsr-late-$$"
( sleep 4; exec env INTER_SESSION_PPID_OVERRIDE=100033 "$PY" "$IS_BIN/client.py" --name "$LN" > "$W/late.out" 2>&1 ) & LATE=$!
t=$(date +%s); out="$(BUS_SEND_RETRY_S=20 send "$LN" late-hello 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
for i in $(seq 1 20); do /usr/bin/grep -q late-hello "$W/late.out" 2>/dev/null && break; sleep 0.25; done
[ $rc -eq 0 ] && /usr/bin/grep -q 'sent on try' <<<"$out" && /usr/bin/grep -q late-hello "$W/late.out" 2>/dev/null \
  && ok "4 name joined after ~4 s: delivered ($(/usr/bin/grep -o 'sent on try [0-9]*' <<<"$out"), ${dt}s)" \
  || no "4 rc=$rc dt=$dt out=$out late=$(head -3 "$W/late.out" 2>/dev/null)"

# 5 a refusal that is NOT an absent name is not retried (a target matching the sender's own name)
t=$(date +%s); out="$(BUS_SEND_RETRY_S=20 send bsr self 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
[ $rc -eq 1 ] && [ $dt -le 5 ] && ok "5 non-absent refusal not retried: rc 1 in ${dt}s ($(printf '%s' "$out" | tail -1 | cut -c1-50))" \
  || no "5 rc=$rc dt=$dt: $out"

# 6 the live bus was not touched
LIVE="$HOME/.claude/data/inter-session/messages.log"
[ ! -f "$LIVE" ] || ! /usr/bin/grep -q "bsr-" "$LIVE" && ok "6 live messages.log holds no bsr- row" || no "6 live bus touched"

printf 'bus-send-retry: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

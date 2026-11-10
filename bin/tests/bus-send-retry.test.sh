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

# 7 a successful send returns once the bus has handled it, not after the fallback wait (_ACK_S): a `ping`
#   follows the send on the same connection and its pong confirms the send (the server handles frames
#   in order and acknowledges nothing else). The fallback is raised to 30 s in-process, so a send that
#   waited for it takes 30 s and one confirmed by the pong returns long before; the 15 s bound leaves room
#   for a loaded host. (A wall-clock bound of 1500 ms on the normal 2 s fallback failed under load.)
t=$(date +%s); out="$(BUS_SEND_RETRY_S=0 INTER_SESSION_NO_REEXEC=1 PYTHONDONTWRITEBYTECODE=1 timeout 60 "$VPY" - "$BS" "$SINK" "timing-probe-$$" 2>&1 <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m._ACK_S = 30.0
sys.argv = ["bus-send.py", "--name", "bsr", "--to", sys.argv[2], "--text", sys.argv[3]]
sys.exit(m.main())
PYEOF
)"; rc=$?; dt=$(( $(date +%s) - t ))
for i in $(seq 1 20); do grep -q "timing-probe-$$" "$W/sink.out" 2>/dev/null && break; sleep 0.1; done
[ $rc -eq 0 ] && [ $dt -lt 15 ] && grep -q "timing-probe-$$" "$W/sink.out" \
  && ok "7 success confirmed in ${dt}s with a 30 s fallback (pong, not the fallback), and delivered" || no "7 rc=$rc ${dt}s: $out"

# 8 no port: refused with exit 2 and nothing sent, also with TEAM_RUN_ID set (it does not name the
#   port); the skill's default port is not a team bus. --port names the bus explicitly.
out="$(env -u INTER_SESSION_PORT -u TEAM_PORT "$PY" "$BS" --name bsr --to "$SINK" --text "noport-$$" 2>&1)"; rc=$?
out2="$(env -u INTER_SESSION_PORT -u TEAM_PORT TEAM_RUN_ID=testbsr "$PY" "$BS" --name bsr --to "$SINK" --text "noport-$$" 2>&1)"; rc2=$?
sleep 0.3
[ $rc -eq 2 ] && [ $rc2 -eq 2 ] && /usr/bin/grep -q 'no bus port' <<<"$out$out2" && ! /usr/bin/grep -q "noport-$$" "$W/sink.out" \
  && ok "8 no port (with or without TEAM_RUN_ID): exit 2, nothing sent" || no "8 rc=$rc/$rc2: $out / $out2"
out="$(env -u INTER_SESSION_PORT -u TEAM_PORT BUS_SEND_RETRY_S=0 "$PY" "$BS" --name bsr --port "$PORT" --to "$SINK" --text "viaport-$$" 2>&1)"; rc=$?
for i in $(seq 1 20); do /usr/bin/grep -q "viaport-$$" "$W/sink.out" 2>/dev/null && break; sleep 0.1; done
[ $rc -eq 0 ] && /usr/bin/grep -q "viaport-$$" "$W/sink.out" && ok "8 --port: sent and delivered" || no "8 --port rc=$rc: $out"

# 9 a bus that accepts and never answers is bounded. A stand-in server with its own data dir, token,
#   port and pidfile (at <dir>/bin/server.py, so the identity check passes) in four modes: tcp (accepts,
#   never speaks: the handshake hangs), ws (handshake done, no welcome: the welcome recv hung forever),
#   close (handshake, then hangs up), mute (welcome, then no answer to the send or to the `ping` behind
#   it: this was reported as sent). Each must end in rc 1 with ONE stderr line and no traceback.
FAKE=""; trap 'kill "$FAKE" 2>/dev/null; cleanup' EXIT
mkdir -p "$W/fake/bin" "$W/fdata"; printf 'fake-token-%s\n' "$$" > "$W/fdata/token"
cat > "$W/fake/bin/server.py" <<'PYEOF'
import asyncio, socket, sys
mode, port = sys.argv[1], int(sys.argv[sys.argv.index("--port") + 1])
if mode == "tcp":
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(8); held = []
    while True:
        c, _ = s.accept(); held.append(c)
import websockets
async def handler(ws, *a):
    if mode == "close":
        await ws.close(); return
    if mode == "mute":
        await ws.recv(); await ws.send('{"op": "welcome"}')
    await asyncio.sleep(3600)
async def main():
    async with websockets.serve(handler, "127.0.0.1", port):
        await asyncio.Future()
asyncio.run(main())
PYEOF
want() { case "$1" in tcp) echo 'no websocket handshake from' ;; ws) echo 'accepted but sent no welcome' ;; close) echo 'closed the connection' ;; mute) echo 'no answer from the bus within' ;; esac; }
for mode in tcp ws close mute; do
  fport="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')"
  "$VPY" "$W/fake/bin/server.py" "$mode" --port "$fport" >/dev/null 2>&1 & FAKE=$!
  for i in $(seq 1 50); do "$PY" -c 'import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$fport" && break; sleep 0.1; done
  INTER_SESSION_DATA_DIR="$W/fdata" "$VPY" - "$fport" "$FAKE" "$IS_BIN" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[3])
import shared
shared.pidfile_path(int(sys.argv[1]), "127.0.0.1").write_text(sys.argv[2] + "\n")
PYEOF
  t=$(date +%s)
  timeout 40 env INTER_SESSION_DATA_DIR="$W/fdata" INTER_SESSION_PORT="$fport" BUS_SEND_RETRY_S=0 \
    "$PY" "$BS" --name bsr --to nobody --text probe >"$W/fo" 2>"$W/fe" </dev/null; rc=$?; dt=$(( $(date +%s) - t ))
  [ $rc -eq 1 ] && [ $dt -le 20 ] && /usr/bin/grep -qF "$(want "$mode")" "$W/fe" && [ "$(/usr/bin/grep -c . "$W/fe")" = 1 ] \
    && ! /usr/bin/grep -q Traceback "$W/fe" && ! /usr/bin/grep -q 'sent ->' "$W/fo" \
    && ok "9 [$mode] bounded: rc 1 after ${dt}s, one line: $(head -c 70 "$W/fe")" || no "9 [$mode] rc=$rc after ${dt}s: $(head -3 "$W/fe")"
  kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""
done
# 9 the bounded hello and payload sends: a bus that stops taking frames. No server can be made to hold
#   a frame this small, so the websocket is a stand-in in-process whose send never completes (the
#   hello's, or the payload's after a welcome); _STEP_S is cut to 0.5 s. Before, the TimeoutError
#   ended in a traceback.
for mode in hello payload; do
  INTER_SESSION_DATA_DIR="$W/fdata" INTER_SESSION_PORT=1 BUS_SEND_RETRY_S=0 INTER_SESSION_NO_REEXEC=1 \
    PYTHONDONTWRITEBYTECODE=1 timeout 40 "$VPY" - "$BS" "$mode" >"$W/fo" 2>"$W/fe" <<'PYEOF'
import asyncio, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mode = sys.argv[2]
class WS:
    sends = 0
    async def send(self, data):
        WS.sends += 1
        if mode == "hello" or WS.sends > 1:
            await asyncio.sleep(3600)
    async def recv(self):
        return json.dumps({"op": "welcome"})
    async def close(self):
        pass
async def connect(*a, **k):
    return WS()
import websockets.exceptions   # the real connect imports it; _run's except clauses name it
m.websockets.connect = connect
m.shared.verify_server_identity = lambda host, port: True
m._STEP_S = 0.5
sys.argv = ["bus-send.py", "--name", "bsr", "--to", "nobody", "--text", "probe"]
sys.exit(m.main())
PYEOF
  rc=$?
  [ $rc -eq 1 ] && grep -qF 'did not take a frame within' "$W/fe" && [ "$(grep -c . "$W/fe")" = 1 ] \
    && ! grep -q Traceback "$W/fe" && ! grep -q 'sent ->' "$W/fo" \
    && ok "9 [$mode send] bounded: rc 1, one line: $(head -c 70 "$W/fe")" || no "9 [$mode send] rc=$rc: $(head -3 "$W/fe")"
done

# 6 the live bus was not touched
LIVE="$HOME/.claude/data/inter-session/messages.log"
[ ! -f "$LIVE" ] || ! /usr/bin/grep -q "bsr-" "$LIVE" && ok "6 live messages.log holds no bsr- row" || no "6 live bus touched"

printf 'bus-send-retry: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

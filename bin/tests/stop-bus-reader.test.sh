#!/usr/bin/env bash
# The Stop hook blocks a team role whose bus reader is unarmed or whose listener is
# dead, and allows everything else (armed reader, non-team session, stop_hook_active, a hanging status call).
# Fixture: a scratch inbox dir with a FAKE pump and client (argv shaped like the real ones, so the real
# bus-inbox.py `status` judges them) and a fake tmux on PATH. No live role's inbox, no live tmux, no bus.
set -u
repo="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${STOP_HOOK:-$repo/bin/hooks/stop-bus-reader.sh}"
W="$(mktemp -d)"; export NOTIFY_SINK="$W/notify.sink" WATCH_ALERT_SINK="$W/watch.sink"
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf -- "$W"; }
trap cleanup EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "  PASS  $1"; }
no() { fail=$((fail+1)); echo "  FAIL  $1"; }
LIVE_MSGS="$HOME/.claude/data/inter-session/messages.log"; live0="$(wc -l < "$LIVE_MSGS" 2>/dev/null || echo 0)"

export TEAM_DIR="$W/team" BUS_INBOX_DIR="$W/inbox" TEAM_SESSION="orch-test"
mkdir -p "$TEAM_DIR" "$BUS_INBOX_DIR" "$W/fk" "$W/bin"
LOGF="$W/stop.log"; export STOP_BUS_READER_LOG="$LOGF"
printf 'import time\ntime.sleep(600)\n' > "$W/fk/bus-inbox.py"; cp "$W/fk/bus-inbox.py" "$W/fk/client.py"
# every background fixture is off stdout: a survivor holding the pipe would hang `suite | grep`
sleep 600 >/dev/null 2>&1 & CC=$!; pids="$pids $CC"
python3 "$W/fk/bus-inbox.py" _pump rolex "$CC" >/dev/null 2>&1 & PUMP=$!; pids="$pids $PUMP"
python3 "$W/fk/client.py" --name rolex >/dev/null 2>&1 & CLI=$!; pids="$pids $CLI"
echo "$PUMP $CLI" > "$BUS_INBOX_DIR/rolex.pid"; : > "$BUS_INBOX_DIR/rolex.log"
# fake tmux: `display` prints "$FAKE_TMUX_OUT"; `list-panes` prints "$FAKE_TMUX_PANES" (index id; default one pane %1)
cat > "$W/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display) printf '%s\n' "${FAKE_TMUX_OUT:-}" ;;
  list-panes) printf '%b\n' "${FAKE_TMUX_PANES:-0 %1}" ;;
esac
TMUX
chmod +x "$W/bin/tmux"
# DETACHED stand-ins (parent re-assigned, no claude above them): the role's OWN claude for the window fallback.
# A plain `sleep &` here sits under whatever claude runs this suite and would read as NESTED.
detached() { local f="$W/det.$1"; shift
  ( setsid "$@" >/dev/null 2>&1 < /dev/null & echo $! > "$f" ) ; sleep 0.3; cat "$f"; }
DCC="$(detached cc sleep 600)"; pids="$pids $DCC"
# llm-judge.sh / observer.sh shape: `claude -p --model <m>`, detached
printf 'import time\ntime.sleep(600)\n' > "$W/fk/claude-shape.py"
PCC="$(detached p python3 "$W/fk/claude-shape.py" -p --model x)"; pids="$pids $PCC"
# NESTED: a process under a fake claude (argv0 named claude)
ln -s "$(command -v python3)" "$W/fk/claude"
"$W/fk/claude" -c 'import subprocess,sys,time; p=subprocess.Popen(["sleep","600"]); open(sys.argv[1],"w").write(str(p.pid)); time.sleep(600)' "$W/nested.pid" >/dev/null 2>&1 & FCL=$!; pids="$pids $FCL"
sleep 0.5; NCC="$(cat "$W/nested.pid")"; pids="$pids $NCC"
sleep 0.5

# run_hook <stdin-json> [VAR=val ...]: stdout to $W/out, rc to $rc, duration to $dt
# env options (-u) and assignments in "$@" follow the defaults below, so a case can override or unset them.
export PATH="$W/bin:$PATH" STOP_BUS_READER_CC_PID="$CC"
run_hook() { local in="$1"; shift; local t0=$SECONDS
  printf '%s' "$in" | env -u TMUX_PANE "$@" bash "$HOOK" > "$W/out" 2>"$W/err"; rc=$?; dt=$((SECONDS - t0)); }
blocked() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("decision")=="block" else 1)' "$W/out" 2>/dev/null; }

echo "== 1. live listener, no reader: BLOCK =="
run_hook '{"stop_hook_active":false}'
[ "$rc" = 0 ] && ok "exit 0 (the verdict is the JSON, not the exit code)" || no "rc=$rc"
blocked && ok "decision=block" || no "not blocked: $(cat "$W/out" "$W/err")"
/usr/bin/grep -q 'not armed' "$W/out" && /usr/bin/grep -q 'bus-inbox.py wait rolex 7200' "$W/out" \
  && ok "the reason names the arm command for this role" || no "reason: $(cat "$W/out")"
/usr/bin/grep -q 'rolex BLOCK reader=none' "$LOGF" && ok "logged" || no "no log line"

echo "== 2. reader armed: allow =="
# ONE process holds the reader lock (flock(1) would fork a sleep that outlives a kill of flock)
( exec 9>"$BUS_INBOX_DIR/rolex.lock.reader"; flock 9; exec sleep 600 ) >/dev/null 2>&1 & RD=$!; pids="$pids $RD"; sleep 0.5
run_hook '{}'
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "armed reader: no output, exit 0" || no "rc=$rc out=$(cat "$W/out")"
kill "$RD" 2>/dev/null; wait "$RD" 2>/dev/null; sleep 0.3
run_hook '{}'; blocked && ok "CONTROL: reader released -> blocks again" || no "control did not block"

echo "== 3. stop_hook_active: never block twice =="
run_hook '{"stop_hook_active":true}'
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "stop_hook_active=true: allowed" || no "rc=$rc out=$(cat "$W/out")"
/usr/bin/grep -q 'rolex stop_hook_active: allowed' "$LOGF" && ok "logged" || no "no log line"

echo "== 4. status hangs: fail open within the timeout =="
printf 'import time\ntime.sleep(30)\n' > "$W/fk/hang.py"
run_hook '{}' STOP_BUS_READER_BUS_INBOX="$W/fk/hang.py" STOP_BUS_READER_TIMEOUT=2
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "hanging status: allowed" || no "rc=$rc out=$(cat "$W/out")"
[ "$dt" -le 4 ] && ok "returned in ${dt}s (timeout 2 s)" || no "took ${dt}s"
/usr/bin/grep -q 'status timed out after 2s' "$LOGF" && ok "logged as a timeout" || no "no timeout log line"
printf 'import sys\nsys.exit(7)\n' > "$W/fk/err.py"
run_hook '{}' STOP_BUS_READER_BUS_INBOX="$W/fk/err.py"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "erroring status (rc 7): allowed, fail open" || no "rc=$rc out=$(cat "$W/out")"

echo "== 5. not a team role: allow =="
run_hook '{}' STOP_BUS_READER_CC_PID=999999999
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "no pump for this session, no pane: allowed" || no "rc=$rc out=$(cat "$W/out")"
run_hook '{}' -u TEAM_DIR
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "no TEAM_DIR (a session outside any team run): allowed" || no "rc=$rc out=$(cat "$W/out")"
run_hook '{}' STOP_BUS_READER_CC_PID=999999999 TMUX_PANE=%1 FAKE_TMUX_OUT="other-sess rolex"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "a pane in another tmux session: allowed" || no "rc=$rc out=$(cat "$W/out")"
run_hook '{}' STOP_BUS_READER_CC_PID=999999999 TMUX_PANE=%1 FAKE_TMUX_OUT="orch-test shell"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "a team-session window with no inbox (not a role): allowed" || no "rc=$rc out=$(cat "$W/out")"

echo "== 6. the window fallback names the role only for the role's own claude =="
fx="$(tr '\0' ' ' < "/proc/$DCC/cmdline")"; ppid_d="$(awk '{print $4}' "/proc/$DCC/stat")"
[ "$ppid_d" != "$$" ] && ok "fixture: the detached stand-in is not this suite's child (ppid $ppid_d)" || no "fixture: detached cc still a child"
W6=(TMUX_PANE=%1 FAKE_TMUX_OUT="orch-test rolex")
run_hook '{}' STOP_BUS_READER_CC_PID="$DCC" "${W6[@]}"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "listener ALIVE for another claude, this one named only by the window: allowed" || no "rc=$rc out=$(cat "$W/out")"
/usr/bin/grep -q 'another claude owns it' "$LOGF" && ok "logged as owned by another claude" || no "no owner log line"
kill "$PUMP" 2>/dev/null; wait "$PUMP" 2>/dev/null; sleep 0.3
run_hook '{}' STOP_BUS_READER_CC_PID="$DCC" "${W6[@]}"
[ "$rc" = 0 ] && blocked && ok "listener DEAD, the role's own claude (first pane, not nested, not -p): decision=block" || no "rc=$rc out=$(cat "$W/out") err=$(cat "$W/err")"
/usr/bin/grep -q 'DEAD' "$W/out" && /usr/bin/grep -q 'bus-inbox.py start rolex' "$W/out" && /usr/bin/grep -q 'wait rolex 7200' "$W/out" \
  && ok "the reason gives start, then arm" || no "reason: $(cat "$W/out")"
run_hook '{}' STOP_BUS_READER_CC_PID="$PCC" "${W6[@]}"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "a claude -p --model (llm-judge.sh shape) in the role's pane: allowed" || no "rc=$rc out=$(cat "$W/out")"
run_hook '{}' STOP_BUS_READER_CC_PID="$NCC" "${W6[@]}"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "a claude nested under another claude: allowed" || no "rc=$rc out=$(cat "$W/out")"
run_hook '{}' STOP_BUS_READER_CC_PID="$DCC" "${W6[@]}" FAKE_TMUX_PANES='0 %0\n1 %1'
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "a claude in the window's SECOND pane: allowed" || no "rc=$rc out=$(cat "$W/out")"
run_hook '{}' STOP_BUS_READER_CC_PID="$DCC"
[ "$rc" = 0 ] && [ ! -s "$W/out" ] && ok "dead listener and no pane: cannot name the role, allowed" || no "rc=$rc out=$(cat "$W/out")"

echo "== 6b. a repo path with a space is quoted in the instruction =="
SP="$W/sp ace"; mkdir -p "$SP/bin/hooks"; cp "$HOOK" "$SP/bin/hooks/"
printf '{}' | env -u TMUX_PANE STOP_BUS_READER_CC_PID="$DCC" STOP_BUS_READER_BUS_INBOX="$repo/bin/bus-inbox.py" "${W6[@]}" bash "$SP/bin/hooks/stop-bus-reader.sh" > "$W/out" 2>&1
/usr/bin/grep -qF 'sp\\ ace/bin/bus-inbox.py start rolex' "$W/out" && ok "the path is shell-quoted" || no "unquoted: $(cat "$W/out")"

echo "== 6c. the audit log is capped =="
head -c 300 /dev/zero | tr '\0' x > "$W/cap.log"
run_hook '{}' STOP_BUS_READER_CC_PID="$DCC" "${W6[@]}" STOP_BUS_READER_LOG="$W/cap.log" STOP_BUS_READER_LOG_MAX=200
[ -f "$W/cap.log.1" ] && [ "$(stat -c %s "$W/cap.log.1")" = 300 ] && [ "$(stat -c %s "$W/cap.log")" -lt 200 ] \
  && ok "over the cap: moved to .1, a fresh log started" || no "cap: $(ls -l "$W"/cap.log*)"

echo "== 7. nothing reached a live channel =="
[ ! -s "$NOTIFY_SINK" ] && [ ! -s "$WATCH_ALERT_SINK" ] && ok "sinks empty" || no "a sink was written"
[ "$(wc -l < "$LIVE_MSGS" 2>/dev/null || echo 0)" -ge "$live0" ] && ! tail -n +"$((live0+1))" "$LIVE_MSGS" 2>/dev/null | /usr/bin/grep -q rolex \
  && ok "the live bus holds no rolex line" || no "rolex reached the live bus"

echo
echo "stop-bus-reader: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

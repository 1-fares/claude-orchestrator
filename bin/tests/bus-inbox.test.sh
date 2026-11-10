#!/usr/bin/env bash
# bus-inbox.py + the bus-send.py unknown_peer retry. PRIVATE BUS ONLY: own INTER_SESSION_DATA_DIR and
# a free port, as bus-send-daemon-context.test.sh does; the live bus is never touched, and a
# precondition row proves it before anything is sent. The role's Claude Code process is stood in for
# by a `sleep` (BUS_INBOX_CC_PID), so "the role dies" is `kill` of that sleep. A throwaway observer
# peer lists the private bus (list.py needs a session of its own).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY=python3
IS_BIN="$HOME/.claude/skills/is/bin"
IB="$repo/bin/bus-inbox.py"; BS="$repo/bin/bus-send.py"
pass=0 fail=0
ok() { printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
printf 'bus-inbox: starting\n'

W="$(mktemp -d)"; PORT="$("$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')"
export INTER_SESSION_DATA_DIR="$W/data" INTER_SESSION_PORT="$PORT" BUS_INBOX_DIR="$W/inbox"
export NOTIFY_SINK="$W/notify.sink" WATCH_ALERT_SINK="$W/watch.sink" INTER_SESSION_OWNER_CHECK_INTERVAL_S=1
unset TEAM_PORT TEAM_RUN_ID TEAM_DIR
mkdir -p "$W/data"
sleep 100000 & CC=$!; export BUS_INBOX_CC_PID=$CC
N="ibx-role-$$"
OBS="ibx-obs-$$"; OBSKEY=100034
INTER_SESSION_PPID_OVERRIDE=$OBSKEY "$PY" "$IS_BIN/client.py" --name "$OBS" > "$W/obs.out" 2>&1 & OBSPID=$!
cleanup() {
  for f in "$W"/inbox/*.pid; do [ -f "$f" ] && for p in $(cat "$f"); do kill "$p" 2>/dev/null; done; done
  kill "$CC" "$OBSPID" 2>/dev/null; [ -n "${CC2:-}" ] && kill "$CC2" 2>/dev/null
  [ -f "$W/data/server.$PORT.pid" ] && kill "$(head -1 "$W/data/server.$PORT.pid" | tr -dc 0-9)" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
[ "$(realpath -m "$INTER_SESSION_DATA_DIR")" != "$(realpath -m "$HOME/.claude/data/inter-session")" ] \
  && ok "PRECONDITION: private data dir, port $PORT" || { no "data dir IS the live one -- refusing"; exit 1; }
onbus() { local l; l="$(INTER_SESSION_PPID_OVERRIDE=$OBSKEY "$PY" "$IS_BIN/list.py" 2>/dev/null | awk 'NR>1 {print $1}')"
  /usr/bin/grep -qx -- "$1" <<<"$l"; }
for i in $(seq 1 60); do onbus "$OBS" && break; sleep 0.25; done
onbus "$OBS" && ok "PRECONDITION: observer $OBS lists the private bus" || { no "observer did not come up"; exit 1; }

send() { BUS_SEND_NAME=ibx-sender "$PY" "$BS" --name ibx-sender --to "${2:-$N}" --text "$1"; }
nmsg() { /usr/bin/grep -c '^\[inter-session msg=' "$1" 2>/dev/null || true; }
procs_for() {  # pids whose cmdline is client.py --name $1 or bus-inbox.py _pump $1 (scan /proc, no pgrep -f)
  # Builtins only: a fork per process made each scan cost about a second. Each argument is joined
  # with a trailing space, as `tr '\0' ' '` did, so "--name $1 " does not match a longer name.
  local d c a
  for d in /proc/[0-9]*; do
    { mapfile -d '' -t a < "$d/cmdline"; } 2>/dev/null || continue
    [ "${#a[@]}" -gt 0 ] || continue
    printf -v c '%s ' "${a[@]}"
    case "$c" in *"client.py --name $1 "*|*"bus-inbox.py _pump $1 "*) echo "${d#/proc/}";; esac; done; }
orphan_listeners() {  # a client.py listener for $1 whose parent is init (re-parented, owner gone)
  for p in $(procs_for "$1"); do c="$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)"
    case "$c" in *"/skills/is/bin/client.py --name "*) :;; *) continue;; esac
    s="$(cat /proc/$p/stat 2>/dev/null)"; s="${s##*) }"; [ "$(echo "$s" | awk '{print $2}')" = 1 ] && echo "$p"; done; }

# TN names: a trailing hyphen (a typo such as "impl-"), a leading hyphen and 41 characters are refused
#    with 64 and leave no state; one character, an inner hyphen and 40 characters are valid names.
a40="$(printf 'a%.0s' $(seq 1 39))b"; nok=1; gok=1
for nm in "ibx-x-" "-x" "${a40}c"; do "$PY" "$IB" status "$nm" >/dev/null 2>&1; r=$?
  [ $r -eq 64 ] && [ ! -e "$W/inbox/$nm.lock.reader" ] || { nok=0; echo "    refused? '$nm' rc=$r"; }; done
for nm in "a" "ibx-a-b" "$a40"; do "$PY" "$IB" status "$nm" >/dev/null 2>&1; r=$?
  [ $r -eq 2 ] || { gok=0; echo "    valid? '$nm' rc=$r"; }; done
[ $nok = 1 ] && [ $gok = 1 ] && ok "TN name check: trailing/leading hyphen and 41 chars refused (64); 1, inner hyphen, 40 chars valid" \
  || no "TN name check"

# T0 start + positive control
out="$("$PY" "$IB" start "$N" 2>&1)"; rc=$?
[ $rc -eq 0 ] && onbus "$N" && ok "T0 start rc 0 and $N is on the private bus" || { no "T0 start rc=$rc: $out"; exit 1; }

# T1 burst of 3 while a reader waits -> all three, one wake (2 s settle)
# (a burst of back-to-back sends is NOT guaranteed to be one wake: each bus-send call takes a while,
# and the reader returns once the inbox has been quiet for BUS_INBOX_SETTLE_S; count the wakes)
"$PY" "$IB" wait "$N" 60 > "$W/r1" & rp=$!
sleep 1; for i in 1 2 3; do send "burst-$i" >/dev/null; done; wait $rp; wakes=1
while [ "$(nmsg "$W/r1")" -lt 3 ] && [ $wakes -lt 3 ]; do "$PY" "$IB" wait "$N" 10 >> "$W/r1"; wakes=$((wakes+1)); done
n=$(nmsg "$W/r1"); [ "$n" -eq 3 ] && [ "$(sort -u "$W/r1" | /usr/bin/grep -c 'burst-')" -eq 3 ] \
  && ok "T1 burst: 3/3 delivered, no duplicate, in $wakes wake(s)" || no "T1 burst: $n/3 after $wakes wakes"

# T2 message while no reader runs -> next reader returns it
send "handover-1" >/dev/null; sleep 1
"$PY" "$IB" wait "$N" 20 > "$W/r2"
/usr/bin/grep -q handover-1 "$W/r2" && ok "T2 sent between readers, returned by the next one" || no "T2 hand-over lost"

# T3 heartbeat
"$PY" "$IB" wait "$N" 3 > "$W/r3"; rc=$?
[ $rc -eq 0 ] && /usr/bin/grep -q HEARTBEAT "$W/r3" && ok "T3 heartbeat, rc 0" || no "T3 rc=$rc $(cat "$W/r3")"

# T8 a second start (and a concurrent pair) -> still exactly one listener
"$PY" "$IB" start "$N" > "$W/s2" 2>&1 & s2p=$!; "$PY" "$IB" start "$N" > "$W/s3" 2>&1; wait $s2p   # NOT bare wait: the CC stand-in is a job too
c=$(procs_for "$N" | /usr/bin/grep -c . ); clients=0
for p in $(procs_for "$N"); do /usr/bin/grep -qa client.py /proc/$p/cmdline && clients=$((clients+1)); done
[ "$clients" -eq 1 ] && /usr/bin/grep -q 'already running' "$W/s2" && /usr/bin/grep -q 'already running' "$W/s3" \
  && ok "T8 two more starts: 'already running' twice, $clients client process" || no "T8 clients=$clients procs=$c"

# T4 client killed hard while a reader waits -> rc 2 LISTENER DEAD
read -r pump client < "$W/inbox/$N.pid"
"$PY" "$IB" wait "$N" 60 > "$W/r4" & rp=$!
sleep 1; kill -9 "$client"; wait $rp; rc=$?
[ $rc -eq 2 ] && /usr/bin/grep -q 'LISTENER DEAD' "$W/r4" && ok "T4 client kill -9 noticed: rc 2" || no "T4 rc=$rc $(cat "$W/r4")"
sleep 1; [ -z "$(procs_for "$N")" ] && ok "T4b pump ended with its client (no leftover process)" || no "T4b leftover: $(procs_for "$N")"

# T5a gap, retry off -> refused at once, today's behaviour
t=$(date +%s); out="$(BUS_SEND_RETRY_S=0 send gap-plain 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
[ $rc -eq 1 ] && [ "$(printf '%s\n' "$out" | tail -1 | cut -c1-38)" = "send error: unknown_peer: no agent mat" ] && [ $dt -le 5 ] \
  && ok "T5a retry off: rc 1 in ${dt}s, last line 'send error: unknown_peer: ...'" || no "T5a rc=$rc dt=$dt: $out"

# T5b gap, default retry, listener back after ~6 s -> delivered
( send gap-retry > "$W/s5" 2>&1; echo $? > "$W/s5.rc" ) & sp=$!
sleep 6; "$PY" "$IB" start "$N" >/dev/null 2>&1; wait $sp
"$PY" "$IB" wait "$N" 20 > "$W/r5"
[ "$(cat "$W/s5.rc")" = 0 ] && /usr/bin/grep -q gap-retry "$W/r5" && /usr/bin/grep -q 'sent on try' "$W/s5" \
  && ok "T5b default retry: delivered after the restart ($(/usr/bin/grep -o 'sent on try [0-9]*' "$W/s5"))" \
  || no "T5b rc=$(cat "$W/s5.rc") $(cat "$W/s5") / $(cat "$W/r5")"
/usr/bin/grep -q gap-plain "$W/inbox/$N.log" && no "T6 refused gap-plain present?!" || ok "T6 control: the refused send is really absent"

# T7 absent name: held about BUS_SEND_RETRY_S, then exactly today's exit and last line
t=$(date +%s); out="$(send nobody-home "ibx-absent-$$" 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
last="$(printf '%s\n' "$out" | tail -1)"
[ $rc -eq 1 ] && [ $dt -ge 26 ] && [ $dt -le 40 ] && [ "${last#send error: unknown_peer: no agent matches}" != "$last" ] \
  && ok "T7 absent name: rc 1 after ${dt}s, last line unchanged ('${last:0:50}')" || no "T7 rc=$rc dt=$dt: $out"
t=$(date +%s); out="$(BUS_SEND_RETRY_S=6 send x "ibx-absent-$$" 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
[ $rc -eq 1 ] && [ $dt -le 10 ] && ok "T7b BUS_SEND_RETRY_S=6 bounds it: rc 1 after ${dt}s" || no "T7b rc=$rc dt=$dt"
t=$(date +%s); out="$(send self ibx-sender 2>&1)"; rc=$?; dt=$(( $(date +%s) - t ))
# a target that IS the sender: refused as a self-send, not as an absent name
[ $rc -eq 1 ] && [ $dt -le 5 ] && ok "T7c non-absent refusal not retried: rc 1 in ${dt}s ($(printf '%s' "$out" | tail -1 | cut -c1-50))" \
  || no "T7c rc=$rc dt=$dt: $out"

# T10 rotation: tiny cap; read everything, then the next append rotates; nothing lost. The cap is read by
# the PUMP, so the listener is restarted with it (first run of this suite set it after the start: no-op).
export BUS_INBOX_CAP_BYTES=200
read -r pump client < "$W/inbox/$N.pid"; kill "$client"; for i in $(seq 1 20); do [ -z "$(procs_for "$N")" ] && break; sleep 0.5; done
"$PY" "$IB" start "$N" >/dev/null 2>&1 || no "T10 restart with cap failed"
"$PY" "$IB" wait "$N" 3 >/dev/null   # consume the old pump's exit line
for i in 1 2; do send "rot-a$i" >/dev/null; done; "$PY" "$IB" wait "$N" 10 > "$W/r10a"
send "rot-b1" >/dev/null; "$PY" "$IB" wait "$N" 10 > "$W/r10b"
[ -f "$W/inbox/$N.log.1" ] && [ "$(stat -c %s "$W/inbox/$N.log")" -lt 400 ] && /usr/bin/grep -q rot-b1 "$W/r10b" \
  && [ "$(cat "$W/r10a" "$W/r10b" | /usr/bin/grep -c 'rot-')" -eq 3 ] \
  && ok "T10 read inbox over cap rotated to .log.1; 3/3 rot- lines delivered" || no "T10 $(ls -l "$W/inbox")"
# T11 UNREAD content over the cap is never rotated away
for i in 1 2 3; do send "unread-$i" >/dev/null; done; sleep 1; send "unread-4" >/dev/null; sleep 1
"$PY" "$IB" wait "$N" 10 > "$W/r11"
[ "$(/usr/bin/grep -c unread- "$W/r11")" -eq 4 ] && ok "T11 unread lines over the cap kept: 4/4 delivered" || no "T11 $(cat "$W/r11")"
unset BUS_INBOX_CAP_BYTES

# F2: a MESSAGE that says "rejected" / "already running" landing in start's 3 s window is mail,
# not a start failure. Deterministic: the line is appended to the inbox while `start` is watching it.
read -r pump client < "$W/inbox/$N.pid"; kill "$client"; for i in $(seq 1 20); do [ -z "$(procs_for "$N")" ] && break; sleep 0.5; done
"$PY" "$IB" wait "$N" 3 >/dev/null 2>&1   # consume the old pump's exit line
( "$PY" "$IB" start "$N" > "$W/f2.out" 2>&1; echo $? > "$W/f2.rc" ) & f2p=$!
sleep 1; printf '[inter-session msg=f2f2f2f2 from="peer"] PR 12 was rejected; deploy already running\n' >> "$W/inbox/$N.log"
wait $f2p
[ "$(cat "$W/f2.rc")" = 0 ] && ok "F2 start rc 0 although a message saying 'rejected'/'already running' landed in its window" \
  || no "F2 start rc=$(cat "$W/f2.rc"): $(cat "$W/f2.out")"
"$PY" "$IB" wait "$N" 5 > "$W/f2r"; /usr/bin/grep -q 'PR 12 was rejected' "$W/f2r" && ok "F2b that message is delivered" || no "F2b $(cat "$W/f2r")"
# F2c control: the CLIENT's own notice in the window IS a failure
read -r pump client < "$W/inbox/$N.pid"; kill "$client"; for i in $(seq 1 20); do [ -z "$(procs_for "$N")" ] && break; sleep 0.5; done
"$PY" "$IB" wait "$N" 3 >/dev/null 2>&1
( "$PY" "$IB" start "$N" > "$W/f2c.out" 2>&1; echo $? > "$W/f2c.rc" ) & f2p=$!
sleep 1; printf '[inter-session] hello rejected: planted by the test\n' >> "$W/inbox/$N.log"; wait $f2p
[ "$(cat "$W/f2c.rc")" = 1 ] && /usr/bin/grep -q 'hello rejected' "$W/f2c.out" && ok "F2c control: a client notice in the window still fails start (rc 1)" \
  || no "F2c rc=$(cat "$W/f2c.rc") $(cat "$W/f2c.out")"
"$PY" "$IB" status "$N" >/dev/null 2>&1 || "$PY" "$IB" start "$N" >/dev/null 2>&1   # the listener itself did come up
"$PY" "$IB" wait "$N" 3 >/dev/null 2>&1

# F3a stdout fails -> rc 4, nothing consumed, the next reader gets it (was: consumed and lost)
send "f3-devfull" >/dev/null; sleep 1
"$PY" "$IB" wait "$N" 10 > /dev/full 2>"$W/f3a.err"; rc=$?
"$PY" "$IB" wait "$N" 5 > "$W/f3a"
[ $rc -eq 4 ] && /usr/bin/grep -q f3-devfull "$W/f3a" && ok "F3a stdout=/dev/full: rc 4, and the next reader delivers the line" \
  || no "F3a rc=$rc next=$(cat "$W/f3a") err=$(head -2 "$W/f3a.err")"
# F3b a locale that cannot encode the text: bytes go out unencoded, nothing lost
send "f3-gruesse-$(printf 'gr\303\274\303\237e \342\234\223')" >/dev/null; sleep 1
LC_ALL=C PYTHONIOENCODING=ascii "$PY" "$IB" wait "$N" 10 > "$W/f3b" 2>"$W/f3b.err"; rc=$?
[ $rc -eq 0 ] && /usr/bin/grep -q "$(printf 'gr\303\274\303\237e')" "$W/f3b" && ok "F3b ASCII-only locale: rc 0, UTF-8 text delivered intact" \
  || { "$PY" "$IB" wait "$N" 3 >> "$W/f3b" 2>/dev/null; no "F3b rc=$rc out=$(cat "$W/f3b") err=$(head -2 "$W/f3b.err")"; }
# F3c one reader per name: a second wait refuses at once and reads nothing; the first gets everything
"$PY" "$IB" wait "$N" 40 > "$W/f3c1" & r1=$!; sleep 1
st="$("$PY" "$IB" status "$N")"
t=$(date +%s); "$PY" "$IB" wait "$N" 20 > "$W/f3c2"; rc2=$?; dt=$(( $(date +%s) - t ))
send "f3c-one" >/dev/null; send "f3c-two" >/dev/null; wait $r1
[ $rc2 -eq 3 ] && [ $dt -le 3 ] && /usr/bin/grep -q 'READER ALREADY RUNNING' "$W/f3c2" && ! /usr/bin/grep -q 'f3c-' "$W/f3c2" \
  && [ "$(/usr/bin/grep -c 'f3c-' "$W/f3c1")" -eq 2 ] && ok "F3c second reader: rc 3 in ${dt}s, read nothing; first reader got 2/2" \
  || no "F3c rc2=$rc2 dt=$dt second=$(cat "$W/f3c2") first=$(cat "$W/f3c1")"
case "$st" in *"reader=armed"*) ok "F3d status shows reader=armed while one waits";; *) no "F3d status: $st";; esac

# C: an inbox deleted or truncated from outside leaves the cursor past the new end.
# The cursor must be reset, logged, and the next messages delivered; before, they were skipped until the
# file grew past the old cursor, and then read from mid-line.
cur0="$(cat "$W/inbox/$N.cursor")"
[ "${cur0:-0}" -gt 0 ] && ok "C0 precondition: cursor at $cur0 bytes" || no "C0 cursor is ${cur0:-empty}, the rows below test nothing"
mv -- "$W/inbox/$N.log" "$W/inbox/$N.log.gone"
send "cur-moved-a" >/dev/null; send "cur-moved-b" >/dev/null; sleep 1
"$PY" "$IB" wait "$N" 10 > "$W/rc1"
[ "$(/usr/bin/grep -c 'cur-moved-' "$W/rc1")" -eq 2 ] && ! /usr/bin/grep -q HEARTBEAT "$W/rc1" \
  && ok "C1 inbox deleted: the next 2 messages delivered" || no "C1 after delete: $(cat "$W/rc1")"
/usr/bin/grep -q 'cursor reset' "$W/inbox/$N.pump.err" && ok "C1b the reset is logged in $N.pump.err" \
  || no "C1b no 'cursor reset' line in $N.pump.err"
: > "$W/inbox/$N.log"
send "cur-trunc-c" >/dev/null; sleep 1
"$PY" "$IB" wait "$N" 10 > "$W/rc2"
/usr/bin/grep -q 'cur-trunc-c' "$W/rc2" && /usr/bin/grep -q '^\[inter-session msg=' "$W/rc2" \
  && ok "C2 inbox truncated to 0: the next message delivered whole" || no "C2 after truncate: $(cat "$W/rc2")"
# C3 the reader's own check, without the pump: a line written straight into a short inbox while the
# cursor points far past its end (the pump's append never runs, so only the reader can reset it)
printf '[inter-session msg=c3c3c3c3 from="peer"] cur-reader-d\n' > "$W/inbox/$N.log"; printf '999999' > "$W/inbox/$N.cursor"
"$PY" "$IB" wait "$N" 10 > "$W/rc3"
/usr/bin/grep -q 'cur-reader-d' "$W/rc3" && ok "C3 a cursor past a short inbox is reset by the reader too" || no "C3 $(cat "$W/rc3")"

# R: SELF-RELOAD of the pump. Runs a COPY of bus-inbox.py from a scratch dir, so the test can edit it.
# BUS_INBOX_SRC overrides the copied file (used to run these rows red-first on an old build).
E="$W/eng"; mkdir -p "$E/bin" "$W/team"
cp "${BUS_INBOX_SRC:-$IB}" "$E/bin/bus-inbox.py"
N2="ibx-rl-$$"; SRLOG="$W/team/audit/watchdog/self-reload.log"
rl_count() { local n; n="$(/usr/bin/grep -c " re-exec $E/bin/bus-inbox.py\$" "$SRLOG" 2>/dev/null)"; echo "${n:-0}"; }   # 0 before the log exists
inh_count() { tr '\0' '\n' < "/proc/$1/cmdline" | /usr/bin/grep -c -- '--inherited-listener-fd'; }
# its OWN stand-in CC: client.py allows one listener per CC session key (one role per CC in real life)
sleep 100000 & CC2=$!
out="$(BUS_INBOX_CC_PID=$CC2 TEAM_DIR="$W/team" SELF_RELOAD_MIN_AGE=4 BUS_INBOX_MARK=env-kept "$PY" "$E/bin/bus-inbox.py" start "$N2" 2>&1)" \
  && ok "R0 reload role started (own CC stand-in $CC2)" || { no "R0 start of the reload role failed: $out"; }
read -r p0 c0 < "$W/inbox/$N2.pid"
printf '\n# reload-1\n' >> "$E/bin/bus-inbox.py"
# a reader waits across the reload; messages are sent around it
"$PY" "$E/bin/bus-inbox.py" wait "$N2" 40 > "$W/rr" & rr=$!
for i in 1 2 3 4 5 6; do send "around-$i" "$N2" >/dev/null; sleep 1; done
for i in $(seq 1 20); do [ "$(rl_count)" -ge 1 ] && break; sleep 1; done
wait $rr; rrc=$?
read -r p1 c1 < "$W/inbox/$N2.pid"
[ "$(rl_count)" -ge 1 ] && [ "$p1" = "$p0" ] && [ "$c1" = "$c0" ] && kill -0 "$c1" 2>/dev/null \
  && ok "R1 reload: audit line written by the new image, same pump pid $p1, same client $c1 (never left the bus)" \
  || no "R1 no reload (audit=$(rl_count) pump $p0->$p1 client $c0->$c1)"
_env="$(tr '\0' '\n' < "/proc/$p1/environ" 2>/dev/null)"; _cmd="$(tr '\0' ' ' < "/proc/$p1/cmdline" 2>/dev/null)"
/usr/bin/grep -qx 'BUS_INBOX_MARK=env-kept' <<<"$_env" \
  && /usr/bin/grep -q "_pump $N2 " <<<"$_cmd" \
  && ok "R1b same environment (marker kept) and same base argv after the exec" || no "R1b env/argv not kept: $(tr '\0' ' ' < /proc/$p1/cmdline 2>/dev/null)"
[ $rrc -eq 0 ] && ! /usr/bin/grep -q 'LISTENER DEAD' "$W/rr" && ok "R3a a reader waiting across the reload was NOT told LISTENER DEAD (rc 0)" \
  || no "R3a reader rc=$rrc $(cat "$W/rr")"
"$PY" "$E/bin/bus-inbox.py" wait "$N2" 5 >> "$W/rr" 2>/dev/null
n=$(sort -u "$W/rr" | /usr/bin/grep -c 'around-'); [ "$n" -eq 6 ] && ok "R3 6/6 messages sent around the reload delivered" || no "R3 $n/6 delivered"
out="$(BUS_INBOX_CC_PID=$CC2 TEAM_DIR="$W/team" "$PY" "$E/bin/bus-inbox.py" start "$N2" 2>&1)"
case "$out" in *"already running"*) ok "R6 start after the reload ADOPTS ('already running'), no second listener";; *) no "R6 $out";; esac
# R2 a SECOND reload (the first always works, the second is where argv rot shows)
printf '# reload-2\n' >> "$E/bin/bus-inbox.py"
for i in $(seq 1 20); do [ "$(rl_count)" -ge 2 ] && break; sleep 1; done
read -r p2 c2 < "$W/inbox/$N2.pid"
[ "$(rl_count)" -ge 2 ] && [ "$p2" = "$p0" ] && [ "$c2" = "$c0" ] && [ "$(inh_count "$p2")" = 1 ] && kill -0 "$c2" 2>/dev/null \
  && ok "R2 second reload clean: one --inherited-listener-fd in argv, same pids" || no "R2 audit=$(rl_count) inh=$(inh_count "$p2") pids $p0/$c0 -> $p2/$c2"
send "after-2nd" "$N2" >/dev/null; "$PY" "$E/bin/bus-inbox.py" wait "$N2" 10 > "$W/rr2"
/usr/bin/grep -q after-2nd "$W/rr2" && ok "R2b delivery works after the second reload" || no "R2b $(cat "$W/rr2")"
# R4 a save that does not compile is NOT loaded; the pump stays alive on the old code; a fix then loads
cp "$E/bin/bus-inbox.py" "$W/good.py"; printf 'def broken(:\n' >> "$E/bin/bus-inbox.py"; before=$(rl_count)
sleep 8
"$PY" "$W/good.py" status "$N2" >/dev/null 2>&1; st=$?   # NOT via the broken file: it cannot even parse
/usr/bin/grep -q 'fails to compile' "$W/inbox/$N2.pump.err" && [ "$(rl_count)" = "$before" ] && [ $st -eq 0 ] \
  && ok "R4 broken save: not loaded, logged 'fails to compile', listener alive" || no "R4 st=$st audit $before->$(rl_count) $(tail -2 "$W/inbox/$N2.pump.err")"
cp "$W/good.py" "$E/bin/bus-inbox.py"; printf '# fixed\n' >> "$E/bin/bus-inbox.py"
for i in $(seq 1 20); do [ "$(rl_count)" -gt "$before" ] && break; sleep 1; done
[ "$(rl_count)" -gt "$before" ] && ok "R4b the next valid save is loaded" || no "R4b fixed file not loaded"

# T9 the role's CC dies -> listener and pump gone, nothing left on the bus, no orphan listener
[ -z "$(orphan_listeners "$N")" ] && ok "T9a while alive: 0 orphan listeners for $N" || no "T9a orphan: $(orphan_listeners "$N")"
kill "$CC"; for i in $(seq 1 20); do [ -z "$(procs_for "$N")" ] && break; sleep 1; done
[ -z "$(procs_for "$N")" ] && ! onbus "$N" && [ -z "$(orphan_listeners "$N")" ] \
  && ok "T9 CC gone -> pump+client exited within ${i}s, $N off the bus, 0 orphans" || no "T9 left: $(procs_for "$N")"
"$PY" "$IB" status "$N" >/dev/null; rc=$?; [ $rc -eq 2 ] && ok "T9b status after death: rc 2" || no "T9b rc=$rc"

# T12 live bus untouched
LIVE="$HOME/.claude/data/inter-session/messages.log"
[ ! -f "$LIVE" ] || ! /usr/bin/grep -q "ibx-" "$LIVE" && ok "T12 live messages.log holds no ibx- row" || no "T12 live bus touched"

printf 'bus-inbox: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# compaction-watchdog: a probe-blind worker. Seen live: two idle workers went probe-blind and
# stayed blind for hours until compacted by hand.
#   - they were idle; every /context probe appended ~8k tokens (~23 KB of transcript),
#     so the probes alone grew them past the window while every /compact was refused
#     (usage limit);
#   - over the window /context prints a banner line above the total, and on an 80x24
#     pane the total line was not readable;
#   - the jsonl fallback read the last 256 KB, which after ~11 probes held no
#     assistant record, only the renders the probes had written ("1.6m/500k tokens
#     (324%)");
#   - the probe-blind alarm is one-shot: it drove /compact once (refused) and never
#     again, and the orchestrator was never told.
# This suite pins: the render read back from the transcript, the wider tail, the
# status-footer read, the forced compact from the footer, and the repeated bus line.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got=[$2] want=[$3]"; }

TD="$(mktemp -d)"; FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$TD" "$FAKEBIN"' EXIT
mkdir -p "$TD/models" "$TD/health" "$TD/proj" "$TD/home/.claude/sessions"
export NOTIFY_SINK="$TD/notify-sink" WATCH_ALERT_SINK="$TD/watch-sink"   # never page from a test
printf '{"autoCompactWindow": 500000}\n' > "$TD/settings.json"
SID=test-session-probe-blind
J="$TD/proj/$SID.jsonl"
printf '{"sessionId":"%s","cwd":"%s"}\n' "$SID" "$TD" > "$TD/home/.claude/sessions/4242.json"
# fable: upstream probes window 0 and fable workers only (every other worker is ceiling-only)
echo fable > "$TD/models/testrole"
echo fable > "$TD/models/orchestrator"

# Transcript records, shaped like the real ones.
asst(){ printf '{"type":"assistant","message":{"role":"assistant","model":"model-a","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$1"; }
render(){ # $1 = total line, e.g. "1.6m/500k tokens (324%)"; $2 = optional banner
  python3 -c '
import json, sys
total, banner = sys.argv[1], sys.argv[2]
body = "<local-command-stdout> Context Usage\n" + (" " + banner + "\n" if banner else "") + \
  "⛁ ⛁   Model A\n⛁ ⛁   model-a\n⛁ ⛁   " + total + "\n" + \
  "         Estimated usage by category\n         Autocompact buffer: 33k tokens (6.6%)\n</local-command-stdout>"
print(json.dumps({"type": "system", "subtype": "local_command", "content": body, "level": "info"}))
print(json.dumps({"type": "user", "message": {"role": "user", "content": "## Context Usage\n\n**Tokens:** x / y (1%)\n"}}))
' "$1" "${2:-}"; }
filler(){ python3 -c 'import json,sys
for i in range(int(sys.argv[1])): print(json.dumps({"type":"user","message":{"role":"user","content":"f"*20000}}))' "$1"; }

# Fake tmux. Pane text comes from $TD/pane; every send-keys is appended to
# $TD/keys; a "/context" Enter appends a render to the transcript when
# $TD/context-writes exists (Claude Code records each /context run there).
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
cmd="${1:-}"; shift || true
case "$cmd" in
  has-session)     exit 0 ;;
  list-sessions)   echo "orch-sess" ;;
  list-windows)    echo "1 testrole" ;;
  display-message) echo 4242 ;;
  capture-pane)    # the bare '❯' row is an input box: bin/lib/tmux-input.sh reads typed text back before Enter
    while IFS= read -r l; do [ "$l" = "❯" ] && l="❯ $(cat "$FAKE_TD/box" 2>/dev/null)"; printf '%s\n' "$l"; done < "$FAKE_TD/pane" ;;
  send-keys)
    printf '%s\n' "$*" >> "$FAKE_TD/keys"
    prev=""; for a in "$@"; do [ "$prev" = "-l" ] && printf '%s' "$a" >> "$FAKE_TD/box"; prev="$a"; done
    case " $* " in *" Enter "*|*" C-u "*) : > "$FAKE_TD/box" ;; esac
    # only testrole's pane (orch-sess:1): the start-up canary probes window 0 and must not write the render
    case "$*" in *"-t orch-sess:1 -l /context"*) : > "$FAKE_TD/context-pending" ;; esac
    case "$*" in *Enter*)
      if [ -e "$FAKE_TD/context-pending" ] && [ -e "$FAKE_TD/context-writes" ]; then
        cat "$FAKE_TD/context-writes" >> "$FAKE_TD/proj/$FAKE_SID.jsonl"
      fi
      rm -f "$FAKE_TD/context-pending" ;;
    esac ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"
# Fake bus sender: record the arguments, succeed (used only by the send-path cases).
cat > "$FAKEBIN/fake-bus-recorder.py" <<'FAKE'
import sys, os
with open(os.environ["FAKE_TD"] + "/bus-sent", "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
FAKE
# Tripwire: the default COMPACT_BUS_SEND in this suite. Anything that would have
# reached a bus lands here, and every loop case asserts it never fired.
cat > "$FAKEBIN/tripwire.py" <<'FAKE'
import sys, os
open(os.environ["FAKE_TD"] + "/tripwire", "a").write(" ".join(sys.argv[1:]) + "\n")
FAKE

envs=( PATH="$FAKEBIN:$PATH" HOME="$TD/home" FAKE_TD="$TD" FAKE_SID="$SID"
  TEAM_DIR="$TD" TEAM_RUN_ID=testrun
  COMPACT_SOCKET=no-such-socket-compaction-test COMPACT_SESSION=orch-sess
  COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log"
  COMPACT_HEALTH_DIR="$TD/health" COMPACT_PROJECT_DIR="$TD/proj"
  COMPACT_SETTINGS_FILE="$TD/settings.json" COMPACT_BUS_SINK="$TD/bus" COMPACT_BUS_SEND="$FAKEBIN/tripwire.py" )
run(){ local snippet="$1"; shift
  env "${envs[@]}" "$@" COMPACT_TEST_SOURCE=1 \
    bash -c ". \"\$0\" >/dev/null 2>&1; $snippet" "$repo/bin/compaction-watchdog.sh"; }

echo "== transcript probe: newest record wins"
{ asst 100000; render "1.6m/500k tokens (324%)" "Context is 1.1m tokens past the 500k-token compaction window — run /compact to reduce usage."; } > "$J"
chk "a render after the last assistant turn is read (over-limit, /500k)" "$(run 'probe_pct_from_jsonl x testrole')" "324"
{ render "1.6m/500k tokens (324%)"; asst 100000; } > "$J"
chk "an assistant turn after the render wins (100000 of 200000)" "$(run 'probe_pct_from_jsonl x testrole')" "50"
asst 250000 > "$J"
chk "assistant usage alone, as before" "$(run 'probe_pct_from_jsonl x testrole')" "125"
render "1m/1m tokens (102%)" "Context is 22.4k tokens past the 1m-token compaction window — run /compact to reduce usage." > "$J"
chk "a render printed against /1m is restated against the 500k setting" "$(run 'probe_pct_from_jsonl x testrole')" "204"
render "1.6m/500k tokens (324%)" > "$J"
chk "no role (canary): the printed percentage, unscaled" "$(run 'probe_pct_from_jsonl x')" "324"
{ printf '{"type":"user","message":{"role":"user","content":"x"}}\n'; } > "$J"
chk "nothing to read -> empty" "$(run 'probe_pct_from_jsonl x testrole || echo rc=$?')" "rc=1"

{ render "1.6m/500k tokens (324%)"; printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info"}\n'; } > "$J"
chk "a render from before a compact_boundary is not read (stale)" "$(run 'probe_pct_from_jsonl x testrole || echo rc=$?')" "rc=1"
{ render "1.6m/500k tokens (324%)"; printf '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info"}\n'; asst 60000; } > "$J"
chk "an assistant turn after the boundary is read (60000 of 200000)" "$(run 'probe_pct_from_jsonl x testrole')" "30"

echo "== transcript probe: the tail"
{ asst 150000; filler 20; } > "$J"   # ~400 KB after the last assistant turn
chk "assistant turn 400 KB back is found (4 MB tail)" "$(run 'probe_pct_from_jsonl x testrole')" "75"
chk "control: with the old 256 KB tail the same file is blind" \
  "$(run 'probe_pct_from_jsonl x testrole || echo rc=$?' COMPACT_JSONL_TAIL_BYTES=262144)" "rc=1"

echo "== status footer"
foot(){ printf '%s\n' "$1" | (. "$repo/bin/lib/compaction-detect.sh"; until_autocompact_pct); }
chk "\"0% until auto-compact\" -> 0" "$(foot '  -- INSERT -- ⏵⏵ bypass permissions on · 0% until auto-compact')" "0"
chk "\"12% until auto-compact\" -> 12" "$(foot '  ⏵⏵ bypass permissions on · 12% until auto-compact')" "12"
chk "\"Context left until auto-compact: 7%\" -> 7" "$(foot '  Context left until auto-compact: 7%')" "7"
chk "no footer -> empty" "$(foot '  -- INSERT -- ⏵⏵ bypass permissions on · 1 shell')" ""
chk "the phrase quoted in a file on the pane is not chrome" "$(foot "  grep -oiE '0% until auto-compact'")" ""

# --- the live loop -------------------------------------------------------------
blind_pane(){ cat > "$TD/pane" <<PANE
  Skills · /skills
  /context all to expand
  Bash results using 107.5k tokens (22%)
────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on · 1 shell$1
PANE
}
# loop_until <cap s> <what> <predicate> [env ...]: run the real loop until <predicate> holds on its log, then stop
# it. Not a fixed `timeout N`: the cases need a number of probe cycles, and under suite load N seconds gave 3
# cycles where 5 were needed. The cap only bounds a hang; reaching
# the predicate is asserted, so a short run fails here by name instead of as a later miscount.
# TERM runs the watchdog's `exit 0` trap after its current command, so a stop can still cut the LAST cycle
# between a send and its log line; the per-send count checks below allow exactly that one trailing cycle.
loop_until(){
  local cap="$1" what="$2" pred="$3" t0="$SECONDS" wp; shift 3
  rm -f "$TD/log" "$TD/keys" "$TD/bus" "$TD/bus-sent" "$TD/tripwire" "$TD/lock" "$TD/pid" "$TD/box"
  env "${envs[@]}" TI_KEY_PAUSE=0.01 TI_SUBMIT_WAIT=0.05 COMPACT_CHECK_INTERVAL=1 COMPACT_IDLE_SEC=0 COMPACT_PROBE_WAIT=0 \
    COMPACT_PROBE_FAIL_ALARM=3 COMPACT_BLIND_BUS_EVERY=2 COMPACT_DEBOUNCE_SEC=900 COMPACT_CANARY_TRIES=0 "$@" \
    timeout "$cap" bash "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 &
  wp=$!
  while kill -0 "$wp" 2>/dev/null && ! "$pred"; do sleep 0.2; done
  kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  if "$pred"; then ok "harness reached: $what ($((SECONDS - t0))s)"
  else no "harness reached: $what" "not within ${cap}s; log: $(tail -3 "$TD/log" 2>/dev/null)"; fi
  if [ -e "$TD/tripwire" ]; then no "nothing reached a real bus" "$(head -1 "$TD/tripwire")"; else ok "nothing reached a real bus"; fi; }
n_of(){ local c; c="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${c:-0}"; }
# logged_per_send <log pattern> <sent file>: every send has its log line, except possibly a stop-cut last one.
logged_per_send(){ local l b; l="$(n_of "$1" "$TD/log")"; b="$(grep -c . "$2" 2>/dev/null)"; b="${b:-0}"
  [ "$b" -ge 1 ] && { [ "$l" = "$b" ] || [ "$l" = "$((b - 1))" ]; }; }
CAP=90
p_bus5(){ [ "$(n_of 'BLIND-BUS: written to the test sink' "$TD/log")" -ge 2 ] && [ "$(n_of 'blind-footer-suppressed' "$TD/log")" -ge 1 ]; }
p_bus_and_footer(){ [ "$(n_of 'BLIND-BUS: written to the test sink' "$TD/log")" -ge 1 ] && [ "$(n_of 'BLIND-FOOTER-COMPACT' "$TD/log")" -ge 1 ]; }
p_bus1(){ [ "$(n_of 'BLIND-BUS: written to the test sink' "$TD/log")" -ge 1 ]; }
p_blind4(){ [ "$(n_of 'testrole\] probe: could not read context' "$TD/log")" -ge 4 ]; }
p_force(){ [ "$(n_of 'testrole\] FORCE: context 324%' "$TD/log")" -ge 1 ]; }
p_notsent(){ [ "$(n_of 'BLIND-BUS: not sent' "$TD/log")" -ge 1 ]; }
p_told(){ [ "$(n_of 'BLIND-BUS: orchestrator told' "$TD/log")" -ge 1 ]; }
p_failed(){ [ "$(n_of 'bus-send FAILED, the orchestrator was NOT told' "$TD/log")" -ge 1 ]; }

echo "== loop: blind idle pane showing 0% until auto-compact"
: > "$J"; rm -f "$TD/context-writes" "$TD/health/compaction-probe-blind-testrole.md"
blind_pane " · 0% until auto-compact"
loop_until $CAP "the cycle-5 bus line and a debounced footer read" p_bus5
fails="$(n_of 'testrole\] probe: could not read context' "$TD/log")"
[ "$fails" -ge 5 ] && ok "harness ran: ${fails} blind cycles logged" || no "harness ran" "only ${fails} blind cycles; log: $(tail -3 "$TD/log" 2>/dev/null)"
chk "one BLIND-FOOTER-COMPACT (debounced after)" "$(n_of 'BLIND-FOOTER-COMPACT' "$TD/log")" "1"
[ "$(n_of 'blind-footer-suppressed' "$TD/log")" -ge 1 ] && ok "later footer reads are debounced, and logged" || no "debounce logged" "$(grep -c footer "$TD/log")"
chk "bus lines at cycles 3 and 5 (every 2)" "$(grep -oE 'for [0-9]+ cycles' "$TD/bus" 2>/dev/null | head -2 | tr '\n' ' ')" "for 3 cycles for 5 cycles "
grep -q -- '--to orchestrator status: compaction-watchdog cannot read testrole' "$TD/bus" \
  && ok "sink line: to orchestrator, status: prefix" || no "sink line shape" "$(head -1 "$TD/bus" 2>/dev/null)"
grep -q 'pane footer: 0% until auto-compact' "$TD/bus" && ok "bus line carries the footer" || no "footer in bus line" "$(head -1 "$TD/bus")"
logged_per_send 'BLIND-BUS: written to the test sink' "$TD/bus" && ok "BLIND-BUS logged as written to the sink, per line" \
  || no "BLIND-BUS logged per sink line" "log $(n_of 'BLIND-BUS: written to the test sink' "$TD/log"), sink $(grep -c . "$TD/bus")"
[ "$(n_of 'orch-sess:1 -l /compact' "$TD/keys")" -ge 1 ] && ok "a /compact was typed into testrole's pane (orch-sess:1)" || no "/compact typed" "$(grep compact "$TD/keys" 2>/dev/null | head -3)"
[ ! -s "$TD/notify-sink" ] && ok "nothing paged" || no "nothing paged" "$(cat "$TD/notify-sink")"

echo "== loop: blind, no footer"
rm -f "$TD/health/compaction-probe-blind-testrole.md"
blind_pane ""
loop_until $CAP "a bus line" p_bus1
chk "no footer -> no BLIND-FOOTER-COMPACT" "$(n_of 'BLIND-FOOTER-COMPACT' "$TD/log")" "0"
[ "$(grep -c . "$TD/bus" 2>/dev/null || echo 0)" -ge 1 ] && ok "no footer -> the bus line still goes" || no "bus without footer" ""
grep -q 'pane footer: none' "$TD/bus" && ok "bus line says footer none" || no "footer none" "$(head -1 "$TD/bus")"

echo "== loop: footer far from the wall (40%) is not acted on"
blind_pane " · 40% until auto-compact"
loop_until $CAP "4 blind cycles" p_blind4
chk "40% left -> no forced compact" "$(n_of 'BLIND-FOOTER-COMPACT' "$TD/log")" "0"

echo "== loop: pane unreadable, the probe's own render is read back from the transcript"
rm -f "$TD/health/compaction-probe-blind-testrole.md"
: > "$J"
render "1.6m/500k tokens (324%)" "Context is 1.1m tokens past the 500k-token compaction window — run /compact to reduce usage." > "$TD/context-writes"
blind_pane ""
loop_until $CAP "the FORCE from the read-back render" p_force
[ "$(n_of 'pane unreadable; read the /context render back from the transcript' "$TD/log")" -ge 1 ] \
  && ok "the render the probe wrote is read on the same pass" || no "render read back" "$(grep testrole "$TD/log" | head -4)"
grep -qE 'testrole\] FORCE: context 324% >= 85%' "$TD/log" && ok "324% -> FORCE compact (fable band 70/85)" || no "FORCE at 324" "$(grep testrole "$TD/log" | head -5)"
chk "no blind cycle once the render is readable" "$(n_of 'could not read context' "$TD/log")" "0"
chk "no bus line once readable" "$(grep -c . "$TD/bus" 2>/dev/null || echo 0)" "0"
rm -f "$TD/context-writes"

echo "== no sink and no state.md (a test that forgot the sink): nothing is sent"
: > "$J"; blind_pane ""
loop_until $CAP "the not-sent line" p_notsent COMPACT_BUS_SINK=
[ "$(n_of 'BLIND-BUS: not sent, .* has no state.md' "$TD/log")" -ge 1 ] && ok "not sent, and logged why" || no "gate logged" "$(grep BLIND "$TD/log")"

echo "== send path (a live team: state.md present, no sink), with a fake bus-send"
: > "$TD/state.md"
loop_until $CAP "a delivered send" p_told COMPACT_BUS_SINK= COMPACT_BUS_SEND="$FAKEBIN/fake-bus-recorder.py"
grep -q -- '--name compaction-watchdog --to orchestrator --text status: compaction-watchdog cannot read testrole' "$TD/bus-sent" \
  && ok "bus-send args: --name compaction-watchdog --to orchestrator, status: prefix" || no "bus-send args" "$(head -1 "$TD/bus-sent" 2>/dev/null)"
logged_per_send 'BLIND-BUS: orchestrator told' "$TD/bus-sent" && ok "BLIND-BUS logged as delivered, per send" \
  || no "BLIND-BUS logged per send" "log $(n_of 'BLIND-BUS: orchestrator told' "$TD/log"), sent $(grep -c . "$TD/bus-sent")"
cat > "$FAKEBIN/bus-fail.py" <<'FAKE'
import sys; sys.exit(1)
FAKE
loop_until $CAP "a failed send" p_failed COMPACT_BUS_SINK= COMPACT_BUS_SEND="$FAKEBIN/bus-fail.py"
[ "$(n_of 'bus-send FAILED, the orchestrator was NOT told' "$TD/log")" -ge 1 ] && ok "failed send logged" || no "failed send logged" "$(grep BLIND "$TD/log")"
rm -f "$TD/state.md"

echo
echo "compaction-probe-blind: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

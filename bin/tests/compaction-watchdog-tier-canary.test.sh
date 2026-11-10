#!/usr/bin/env bash
# compaction-watchdog: which roles count as top tier, the start-up canary, the probe-blind state across restarts, the
# transcript lookup, and the nudge request.
# 1. The top tier is TEAM_MODEL_TOP, else fable (as model_for in bin/lib/team-spawn.sh; the orchestrator's record
#    plays no part, so TEAM_MODEL_ORCHESTRATOR=opus does not lift opus workers),
#    matched as an alias or a full id that contains it. `grep '^fable'` missed "claude-fable-5-2" and TEAM_MODEL_TOP=opus.
# 2. The canary types /context only through process_target's gates: never into a pane that holds a draft or is busy;
#    it waits for the first safe cycle there.
# 3. The consecutive-failure count and the probe-blind marker are files: a count from an earlier process goes on, a
#    marker raised by an earlier process is cleared by a good read and is not raised twice.
# 4. The transcript directory is the cwd with every character other than [A-Za-z0-9] replaced by "-".
# 5. The nudge gives the session one command to run (touch a request file); with the file present and the pane safe
#    the watchdog sends /compact; with a draft in the box it waits.
# Functions only (COMPACT_TEST_SOURCE=1) against a stand-in tmux; no tmux server, no bus, no page. Scratch lives in
# one fixed directory, removed on exit; do not run two copies at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rm -rf /tmp/orch-test-compaction-tier-canary
S=/tmp/orch-test-compaction-tier-canary
TD="$S/team"
H="$TD/health"
mkdir -p "$S/bin" "$S/home" "$TD/models" "$H"
trap 'rm -rf /tmp/orch-test-compaction-tier-canary' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "  ok   $1"; }
bad() { n=$((n+1)); fail=1; echo "  FAIL $1"; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1: got [$2] want [$3]"; }

# Stand-in tmux. Window <w> shows $S/pane.<w>; its bare `❯` row is the input box and shows $S/box.<w>. send-keys is
# logged to $S/keys as "<w> <args>", -l text goes into the box, Enter and C-u empty it.
cat > "$S/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
cmd="${1:-}"; shift || true
t=""; prev=""; for a in "$@"; do [ "$prev" = "-t" ] && t="$a"; prev="$a"; done
w="${t##*:}"
case "$cmd" in
  has-session)     exit 0 ;;
  list-sessions)   echo orch-sess ;;
  list-windows)    cat "$FAKE_S/windows" ;;
  display-message) case "$*" in *pane_current_command*) echo "claude 4242" ;; *) echo 4242 ;; esac ;;
  capture-pane)
    while IFS= read -r l; do [ "$l" = "❯" ] && l="❯ $(cat "$FAKE_S/box.$w" 2>/dev/null)"; printf '%s\n' "$l"; done < "$FAKE_S/pane.$w" ;;
  send-keys)
    printf '%s %s\n' "$w" "$*" >> "$FAKE_S/keys"
    prev=""; for a in "$@"; do [ "$prev" = "-l" ] && printf '%s' "$a" >> "$FAKE_S/box.$w"; prev="$a"; done
    case " $* " in *" Enter "*|*" C-u "*) : > "$FAKE_S/box.$w" ;; esac ;;
esac
exit 0
FAKE
chmod +x "$S/bin/tmux"

# pane <w> <status line>: an idle Claude Code screen with an empty box in INSERT; the status line may carry a total.
pane() { printf '%s\n' '● standing by.' "$2" '────────' '❯' '────────' '  -- INSERT -- ⏵⏵ bypass permissions on' > "$S/pane.$1"; : > "$S/box.$1"; }
busy_pane() { printf '%s\n' '● reading files' '· Working… (3s · esc to interrupt)' '────────' '❯' '────────' '  -- INSERT --' > "$S/pane.$1"; : > "$S/box.$1"; }
rec() { printf '%s\n' "$2" > "$TD/models/$1"; }

run() { # run <snippet> [VAR=value ...]: the snippet runs with the watchdog's functions loaded
  local snippet="$1"; shift
  env -u COMPACT_PRESERVE -u TEAM_MODEL_TOP -u COMPACT_PROJECT_DIR PATH="$S/bin:$PATH" HOME="$S/home" FAKE_S="$S" \
    TEAM_DIR="$TD" TEAM_RUN_ID=testrun NOTIFY_SINK="$S/notify" WATCH_ALERT_SINK="$S/watch" COMPACT_TEST_SOURCE=1 \
    COMPACT_SOCKET=no-such-socket COMPACT_SESSION=orch-sess COMPACT_LOCK="$S/lock" COMPACT_PIDFILE="$S/pid" \
    COMPACT_LOG="$S/log" COMPACT_HEALTH_DIR="$H" COMPACT_SETTINGS_FILE="$S/no-settings" COMPACT_BUS_SINK="$S/bus" \
    COMPACT_BUS_SEND="$S/no-sender" COMPACT_IDLE_SEC=0 COMPACT_PROBE_WAIT=0 TI_KEY_PAUSE=0.01 TI_SUBMIT_WAIT=0.05 "$@" \
    bash -c '. "$0" >/dev/null 2>&1; eval "$1"' "$repo/bin/compaction-watchdog.sh" "$snippet" 2>/dev/null
}
cnt() { local c; c="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${c:-0}"; }
top() { run "role_is_top $1 && echo top || echo no" "${@:2}"; }

echo "== 1: top tier"
rec orchestrator fable; rec w-fable fable; rec w-full claude-fable-5-2; rec w-opus opus; rec w-opus-full claude-opus-5-5
rec w-default default
chk "fable alias is top" "$(top w-fable)" top
chk "a full id that contains fable is top" "$(top w-full)" top
chk "opus is not top with the default top tier" "$(top w-opus)" no
chk "a 'default' record is not top" "$(top w-default)" no
chk "no record is not top" "$(top w-none)" no
chk "TEAM_MODEL_TOP=opus: opus is top" "$(top w-opus TEAM_MODEL_TOP=opus)" top
chk "TEAM_MODEL_TOP=opus: a full opus id is top" "$(top w-opus-full TEAM_MODEL_TOP=opus)" top
chk "TEAM_MODEL_TOP=opus: fable is not top" "$(top w-fable TEAM_MODEL_TOP=opus)" no
chk "TEAM_MODEL_TOP=claude-fable-5-2: the alias fable is top" "$(top w-fable TEAM_MODEL_TOP=claude-fable-5-2)" top
chk "TEAM_MODEL_TOP empty counts as unset" "$(top w-fable TEAM_MODEL_TOP=)" top
rec orchestrator opus
chk "no TEAM_MODEL_TOP, orchestrator record opus: an opus worker is not top" "$(top w-opus)" no
chk "no TEAM_MODEL_TOP, orchestrator record opus: fable is still top" "$(top w-fable)" top
rec orchestrator fable
chk "full fable id: thresholds 70/85" "$(run 'resolve_thresholds w-full; echo "$NUDGE_R/$FORCE_R"')" "70/85"
chk "opus: thresholds 80/90" "$(run 'resolve_thresholds w-opus; echo "$NUDGE_R/$FORCE_R"')" "80/90"
chk "TEAM_MODEL_TOP=opus: opus thresholds 70/85" "$(run 'resolve_thresholds w-opus; echo "$NUDGE_R/$FORCE_R"' TEAM_MODEL_TOP=opus)" "70/85"
printf '0 orchestrator\n1 w-full\n2 w-opus\n' > "$S/windows"
got="$(run 'enumerate_targets' | tr '\n' '|')"
chk "enumerate: window 0 probed, the full-id fable worker probed, opus ceiling-only" "$got" \
  "orchestrator orch-sess:0 1 1|w-full orch-sess:1 0 1|w-opus orch-sess:2 0 0|"

echo "== 2: the canary waits for a safe orchestrator pane"
pane 0 '  12% context used'; printf 'half a draft' > "$S/box.0"; : > "$S/keys"; : > "$S/log"
out="$(run 'p() { process_target orchestrator orch-sess:0 1 1; }; p; p; echo "draft=$CANARY_PENDING"
  busy() { printf "%s\n" "● reading files" "· Working… (3s · esc to interrupt)" "────────" "❯" "────────" > "$FAKE_S/pane.0"; }
  busy; : > "$FAKE_S/box.0"; p; p; echo "busy=$CANARY_PENDING"
  printf "%s\n" "● standing by." "  12% context used" "────────" "❯" "────────" "  -- INSERT --" > "$FAKE_S/pane.0"; p; p
  echo "safe=$CANARY_PENDING"')"
chk "a draft in the box: the canary stays pending" "$(grep -o 'draft=[01]' <<<"$out")" "draft=1"
chk "a busy pane: the canary stays pending" "$(grep -o 'busy=[01]' <<<"$out")" "busy=1"
chk "the first safe cycle runs it" "$(grep -o 'safe=[01]' <<<"$out")" "safe=0"
chk "/context typed exactly once, after the pane was safe" "$(cnt '^0 .*-l /context$' "$S/keys")" "1"
chk "the draft was never cleared" "$(cnt 'cleared typed text' "$S/log")" "0"
chk "skipped for the draft, and logged" "$(cnt 'skip: real unsubmitted text' "$S/log")" "1"
chk "canary healthy, read 12%" "$(cnt 'canary: probe healthy (read 12%)' "$S/log")" "1"
pane 0 '  (no total here)'; : > "$S/keys"; : > "$S/log"
run 'process_target orchestrator orch-sess:0 1 1; process_target orchestrator orch-sess:0 1 1' >/dev/null
chk "no total and no transcript: CANARY-FAIL" "$(cnt 'CANARY-FAIL' "$S/log")" "1"
[ -f "$H/compaction-probe-blind-orchestrator.md" ] && ok "CANARY-FAIL raised the orchestrator's blind marker" || bad "no blind marker after CANARY-FAIL"
chk "the alarm was not raised a second time in the same cycle" "$(cnt 'PROBE-BLIND:' "$S/log")" "0"
chk "the count file holds the failure" "$(cut -d' ' -f1 "$H/compaction-probe-fail-orchestrator" 2>/dev/null)" "1"

echo "== 3: the probe-blind state survives a restart"
pane 1 '  12% context used'; printf '0 orchestrator\n1 w-fable\n' > "$S/windows"
printf 'raised by an earlier process\n' > "$H/compaction-probe-blind-w-fable.md"; printf '5 1700000000\n' > "$H/compaction-probe-fail-w-fable"
: > "$S/log"
run 'process_target w-fable orch-sess:1 0 1; process_target w-fable orch-sess:1 0 1' >/dev/null
[ ! -e "$H/compaction-probe-blind-w-fable.md" ] && ok "a good read clears a marker an earlier process raised" || bad "marker from an earlier process left in place"
chk "PROBE-RECOVERED logged" "$(cnt 'w-fable\] PROBE-RECOVERED' "$S/log")" "1"
[ ! -s "$H/compaction-probe-fail-w-fable" ] && ok "a good read resets the stored count" || bad "count after a good read: $(cat "$H/compaction-probe-fail-w-fable")"
pane 1 '  (no total here)'; printf '2 1700000000\n' > "$H/compaction-probe-fail-w-fable"; : > "$S/log"
run 'process_target w-fable orch-sess:1 0 1; process_target w-fable orch-sess:1 0 1' >/dev/null
chk "a stored count of 2 goes on to 3 (keeps the start time)" "$(cat "$H/compaction-probe-fail-w-fable")" "3 1700000000"
chk "PROBE-BLIND at the third failure across the restart" "$(cnt 'w-fable\] PROBE-BLIND: 3 consecutive' "$S/log")" "1"
[ -f "$H/compaction-probe-blind-w-fable.md" ] && ok "the marker is written" || bad "no marker at 3"
: > "$S/log"
run 'process_target w-fable orch-sess:1 0 1; process_target w-fable orch-sess:1 0 1' >/dev/null
chk "marker present: no second alarm after a restart" "$(cnt 'PROBE-BLIND:' "$S/log")" "0"
chk "the count goes on to 4" "$(cut -d' ' -f1 "$H/compaction-probe-fail-w-fable")" "4"
# The marker cannot be written (read-only health dir; the count file already exists and stays writable): the alarm,
# a /compact into the pane and a notice to the orchestrator, is still raised once per process, not on every cycle.
pane 2 '  (no total here)'; printf '0 orchestrator\n2 w-nowrite\n' > "$S/windows"
printf '2 1700000000\n' > "$H/compaction-probe-fail-w-nowrite"; : > "$S/log"; : > "$S/keys"
chmod 555 "$H"
run 'for i in 1 2 3 4 5 6; do process_target w-nowrite orch-sess:2 0 1; done' >/dev/null
chmod 755 "$H"
chk "unwritable marker: three blind probes in one process" "$(cnt 'w-nowrite\] probe: could not read' "$S/log")" "3"
[ ! -e "$H/compaction-probe-blind-w-nowrite.md" ] && ok "unwritable marker: no marker was written" || bad "the marker was written into a read-only dir"
chk "unwritable marker: the alarm is raised once" "$(cnt 'w-nowrite\] PROBE-BLIND:' "$S/log")" "1"
chk "unwritable marker: one /compact driven by the alarm" "$(cnt '^2 .*-l /compact ' "$S/keys")" "1"

echo "== 4: the transcript directory name"
mkdir -p "$S/home6/.claude/sessions"
for cwd in "/x/.cache/a_b" "$S/home6/work.dir/my_app" "/srv/team space/app"; do
  printf '{"sessionId":"sid1","cwd":"%s"}\n' "$cwd" > "$S/home6/.claude/sessions/4242.json"
  chk "cwd [$cwd]" "$(run 'pane_session orch-sess:0' HOME="$S/home6")" "sid1 $S/home6/.claude/projects/${cwd//[^A-Za-z0-9]/-}/sid1.jsonl"
done

echo "== 5: the nudge request"
pane 1 '  12% context used'; : > "$S/keys"; : > "$S/log"
run 'do_nudge orch-sess:1 75 w-fable' >/dev/null
chk "the nudge names the exact command" "$(cnt "touch \"$H/compact-request-w-fable\"" "$S/keys")" "1"
: > "$H/compact-request-w-fable"; printf 'half a draft' > "$S/box.1"; : > "$S/keys"; : > "$S/log"
run 'process_target w-fable orch-sess:1 0 1; process_target w-fable orch-sess:1 0 1' >/dev/null
chk "request present but a draft in the box: no /compact" "$(cnt '-l /compact' "$S/keys")" "0"
[ -e "$H/compact-request-w-fable" ] && ok "the request waits" || bad "the request was consumed while the box held a draft"
: > "$S/box.1"; : > "$S/keys"; : > "$S/log"
run 'process_target w-fable orch-sess:1 0 1; process_target w-fable orch-sess:1 0 1' >/dev/null
chk "request present, pane safe: /compact sent once" "$(cnt '^1 .*-l /compact ' "$S/keys")" "1"
chk "no /context probe in that cycle" "$(cnt '-l /context' "$S/keys")" "0"
chk "COMPACT-REQUEST logged" "$(cnt 'w-fable\] COMPACT-REQUEST' "$S/log")" "1"
[ ! -e "$H/compact-request-w-fable" ] && ok "the request is consumed" || bad "the request file is still there"

[ "$fail" = 0 ] && echo "compaction-watchdog-tier-canary.test: PASS ($n)" || { echo "compaction-watchdog-tier-canary.test: FAIL"; exit 1; }

#!/usr/bin/env bash
# Test: the watchdog measures NUDGE/FORCE against the configured autoCompactWindow when
# that is smaller than the base it would otherwise use.
#
# Why. With an autoCompactWindow set below the model window, Claude Code compacts on its
# own near that window; NUDGE/FORCE measured against a larger base never fire first, so
# the idle-boundary compaction this daemon exists for never happens.
# Two paths: the transcript read (base JSONL_WINDOW, 200000) and the /context pane read
# (base = the denominator printed on the total line).
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
export NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null    # never page from a test
SET="$TD/settings.json"

SID=test-session-autocompact
transcript(){   # transcript <total tokens>: last assistant message totals exactly that
  { printf '{"type":"user","message":{"role":"user","content":"x"}}\n'
    printf '{"type":"assistant","message":{"role":"assistant","model":"m","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":1}}}\n' "$1"
  } > "$TD/proj/$SID.jsonl"
}
printf '{"sessionId":"%s","cwd":"%s"}\n' "$SID" "$TD" > "$TD/home/.claude/sessions/4242.json"

# Fake tmux; capture-pane prints the /context text held in $TD/ctxpane.
# The socket name does not exist either, so nothing can reach a live pane.
cat > "$FAKEBIN/tmux" <<FAKE
#!/usr/bin/env bash
while [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-f" ]; do shift 2; done
cmd="\${1:-}"; shift || true
case "\$cmd" in
  has-session)     exit 0 ;;
  list-sessions)   echo "orch-sess" ;;
  list-windows)    echo "0 orchestrator" ;;
  display-message) echo 4242 ;;
  capture-pane)    cat "$TD/ctxpane" ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

run() {
  local snippet="$1"; shift
  env "$@" PATH="$FAKEBIN:$PATH" HOME="$TD/home" \
    COMPACT_TEST_SOURCE=1 TEAM_DIR="$TD" TEAM_RUN_ID=testrun \
    COMPACT_SOCKET=no-such-socket-compaction-test COMPACT_SESSION=orch-sess \
    COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" \
    COMPACT_HEALTH_DIR="$TD/health" COMPACT_PROJECT_DIR="$TD/proj" \
    COMPACT_SETTINGS_FILE="$SET" COMPACT_PROBE_WAIT=0 \
    bash -c ". \"\$0\" >/dev/null 2>&1; $snippet" "$repo/bin/compaction-watchdog.sh"
}
M=model-a
echo "$M" > "$TD/models/worker"
ac(){ run "autocompact_window $1"; }
jw(){ run 'jsonl_window worker'; }

# --- settings resolution --------------------------------------------------------
rm -f "$SET"
chk "no settings file -> no autocompact window" "$(ac "$M")" ""
echo '{}' > "$SET"
chk "no key -> none" "$(ac "$M")" ""
echo "{\"modelSettings\":{\"$M\":{\"autoCompactWindow\":150000}}}" > "$SET"
chk "per-model key" "$(ac "$M")" "150000"
echo '{"autoCompactWindow":150000}' > "$SET"
chk "top-level key" "$(ac "$M")" "150000"
echo "{\"autoCompactWindow\":150000,\"modelSettings\":{\"$M\":{\"autoCompactWindow\":120000}}}" > "$SET"
chk "per-model key wins over top-level" "$(ac "$M")" "120000"
echo '{"autoCompactWindow":130000,"modelSettings":{"model-b":{"autoCompactWindow":120000}}}' > "$SET"
chk "another model's key is ignored; top-level applies" "$(ac "$M")" "130000"
for bad in '{"autoCompactWindow":0}' '{"autoCompactWindow":-5}' '{"autoCompactWindow":"500000"}' '{"autoCompactWindow":true}' 'not json'; do
  printf '%s' "$bad" > "$SET"
  chk "invalid setting [$bad] -> none" "$(ac "$M")" ""
done

# --- transcript path: base min(200000, setting) -------------------------------------
rm -f "$SET"
chk "transcript base with no setting: 200000" "$(jw)" "200000"
echo '{"autoCompactWindow":500000}' > "$SET"
chk "a setting above the base never raises it" "$(jw)" "200000"
echo '{"autoCompactWindow":100000}' > "$SET"
chk "a smaller setting lowers it" "$(jw)" "100000"
# POSITIVE CONTROL: 84k tokens, worker band 80/90. Against 200000 that reads 42% and never
# nudges; against a 100000 auto-compact window it reads 84% and MUST nudge.
transcript 84000
p="$(run 'probe_pct_from_jsonl x worker')"
n="$(run 'resolve_thresholds worker; echo $NUDGE_R')"
chk "transcript: 84k under a 100k window reads 84%" "$p" "84"
[ -n "$p" ] && [ "$p" -ge "$n" ] && ok "positive control: 84% >= nudge ${n}% -> nudges" || no "positive control must nudge" "pct=$p nudge=$n"
rm -f "$SET"
p0="$(run 'probe_pct_from_jsonl x worker')"
chk "same 84k with no setting reads 42% (old behaviour)" "$p0" "42"
[ "$p0" -lt "$n" ] && ok "negative control: 42% < nudge -> no nudge" || no "negative control" "pct=$p0"

# --- /context pane path: base = the printed denominator ----------------------------
# Under autoCompactWindow 500000 Claude Code prints "42.1k/500k tokens (8%)": already of
# 500k, so it must NOT be scaled again.
echo '{"autoCompactWindow":500000}' > "$SET"
echo '  420.0k/500k tokens (84%)' > "$TD/ctxpane"
chk "/context printed against 500k stays 84" "$(run 'probe_pct x worker')" "84"
echo '  42.1k/500k tokens (8%)' > "$TD/ctxpane"
chk "/context '42.1k/500k (8%)' stays 8" "$(run 'probe_pct x worker')" "8"
echo '  420.0k/1m tokens (42%)' > "$TD/ctxpane"
chk "/context printed against 1m -> restated against 500k: 84" "$(run 'probe_pct x worker')" "84"
chk "/context without a role stays raw (canary)" "$(run 'probe_pct x')" "42"
printf '  42%% context used\n' > "$TD/ctxpane"
chk "footer only, no denominator on the pane: unchanged 42" "$(run 'probe_pct x worker')" "42"
rm -f "$SET"; echo '  240.0k/1m tokens (24%)' > "$TD/ctxpane"
chk "no setting: a /1m reading stays 24" "$(run 'probe_pct x worker')" "24"
chk "no setting: rescale is the identity" "$(run 'rescale_pct 41 worker 1000000')" "41"
echo '{"autoCompactWindow":500000}' > "$SET"
chk "rescale from 1m rounds up: 41 -> 82" "$(run 'rescale_pct 41 worker 1000000')" "82"
chk "rescale with no denominator is the identity" "$(run 'rescale_pct 41 worker')" "41"
chk "rescale 0 -> 0" "$(run 'rescale_pct 0 worker 1000000')" "0"
chk "rescale empty -> empty" "$(run 'rescale_pct "" worker 1000000')" ""
chk "a setting above the printed window is ignored" "$(run 'rescale_pct 41 worker 200000')" "41"

# --- logging: once, and again on change ---------------------------------------------
: > "$TD/log"; rm -f "$TD/health"/effective-window-*
echo '{"autoCompactWindow":100000}' > "$SET"
for _ in 1 2 3; do run 'jsonl_window worker' >/dev/null; done
chk "effective-window logged once over three calls" "$(grep -c 'effective-window role=worker' "$TD/log")" "1"
grep -q "effective-window role=worker model=$M base=200000 autocompact=100000 effective=100000" "$TD/log" \
  && ok "log line names model, base, setting and the effective one" || no "log line content" "$(cat "$TD/log")"
echo '{"autoCompactWindow":150000}' > "$SET"
run 'jsonl_window worker' >/dev/null
chk "a changed setting logs again" "$(grep -c 'effective-window role=worker' "$TD/log")" "2"

# --- sourcing stops before the daemon starts ----------------------------------------
[ ! -s "$TD/log" ] || ! grep -q 'start: multi-target' "$TD/log" && ok "sourcing never reached the start line or the loop" || no "the daemon started under COMPACT_TEST_SOURCE"

printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]

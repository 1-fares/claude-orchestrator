#!/usr/bin/env bash
# compaction-typing-observed.test.sh: every line the compaction-watchdog types (/context, /compact, /clear, the
# orchestrator's rebrief, the worker notices) goes through bin/lib/tmux-input.sh: it arrives exactly once and exactly as
# given in vim NORMAL as in INSERT, nothing is typed into a menu, and a draft the watchdog clears is logged.
# Sources bin/compaction-watchdog.sh with COMPACT_TEST_SOURCE=1 (functions only, no loop) and drives its functions
# against bin/tests/lib/fake-cc-pane.py panes on a private tmux server: no Claude, no role pane, no model call.
# SRC=<engine tree> sources that tree's watchdog (the red check); the fake is always this tree's. A COMPACT_PRESERVE
# inherited from the caller is dropped, so the default focus text is what is typed.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
FAKE="$repo/bin/tests/lib/fake-cc-pane.py"
command -v tmux >/dev/null || { echo "SKIP: no tmux"; exit 0; }
T="$(mktemp -d)"; SOCK="cto$$"; SES=t
export NOTIFY_SINK="$T/n.sink" WATCH_ALERT_SINK="$T/w.sink" TI_KEY_PAUSE=0.25 TI_SUBMIT_WAIT=0.9
SOCKPATH="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # kill-server leaves the socket file behind
trap 'command tmux -L "$SOCK" kill-server 2>/dev/null; rm -f "$SOCKPATH"; rm -rf "$T"' EXIT
command tmux -L "$SOCK" -f /dev/null new-session -d -s "$SES" -x 160 -y 40 -n base "sleep 600" 2>/dev/null \
  || { echo "SKIP: cannot start a scratch tmux server"; exit 0; }
fail=0; n=0
ok() { n=$((n+1)); echo "  ok   $1"; }
bad() { n=$((n+1)); fail=1; echo "  FAIL $1"; }
mkdir -p "$T/team/models" "$T/health"
pane() { # pane <name> <fake args...>
  local w="$1"; shift
  command tmux -L "$SOCK" new-window -d -t "$SES" -n "$w" "python3 '$FAKE' --log '$T/$w.log' $(printf '%q ' "$@")"
  sleep 0.5
}
# cw <shell code>: run it with the watchdog's functions loaded, against the scratch server.
cw() {
  env -u COMPACT_PRESERVE TEAM_DIR="$T/team" TEAM_RUN_ID=testrun COMPACT_TEST_SOURCE=1 COMPACT_SOCKET="$SOCK" COMPACT_SESSION="$SES" \
    COMPACT_LOCK="$T/lock" COMPACT_PIDFILE="$T/pid" COMPACT_LOG="$T/cw.log" COMPACT_HEALTH_DIR="$T/health" \
    COMPACT_SETTINGS_FILE="$T/no-settings.json" COMPACT_BUS_SINK="$T/bus" COMPACT_PROBE_WAIT=0 \
    bash -c '. "$0" >/dev/null 2>&1; sleep() { command sleep "$(awk -v s="$1" "BEGIN{print (s>1)?1:s}")"; }; eval "$1"' \
    "$SRC/bin/compaction-watchdog.sh" "$1" >/dev/null 2>&1
}
PRESERVE_TEXT="$(env -u COMPACT_PRESERVE COMPACT_TEST_SOURCE=1 TEAM_DIR="$T/team" COMPACT_LOCK="$T/lock" COMPACT_PIDFILE="$T/pid" \
  COMPACT_LOG="$T/cw.log" COMPACT_HEALTH_DIR="$T/health" bash -c '. "$0" >/dev/null 2>&1; printf %s "$PRESERVE"' \
  "$SRC/bin/compaction-watchdog.sh")"
[ -n "$PRESERVE_TEXT" ] || { echo "compaction-typing-observed.test: FAIL (PRESERVE unreadable; the harness is broken)"; exit 1; }

echo "== /compact arrives exactly once, as given, in every mode"
for m in insert normal nonvim; do
  pane "c$m" --mode "$m"; cw "do_compact $SES:c$m"
  [ "$(cat "$T/c$m.log" 2>/dev/null)" = "/compact $PRESERVE_TEXT" ] && ok "do_compact, $m pane: once, intact" \
    || bad "do_compact, $m: $(cut -c1-80 "$T/c$m.log" 2>/dev/null | tr '\n' '|')"
done

echo "== /context arrives exactly once in a NORMAL pane"
pane pn --mode normal; cw "probe_pct $SES:pn >/dev/null"
[ "$(cat "$T/pn.log" 2>/dev/null)" = "/context" ] && ok "probe_pct, normal pane: /context once" || bad "probe_pct normal: $(tr '\n' '|' < "$T/pn.log" 2>/dev/null)"

echo "== the orchestrator recovery: /clear, then the rebrief, each once"
pane rb --mode normal; cw "do_clear_rebrief $SES:rb"
first="$(sed -n 1p "$T/rb.log" 2>/dev/null)"; second="$(sed -n 2p "$T/rb.log" 2>/dev/null)"; lines="$(wc -l < "$T/rb.log" 2>/dev/null)"
[ "$first" = "/clear" ] && [[ "$second" == "You are the orchestrator, auto-recovered"* ]] && [ "$lines" = 2 ] \
  && ok "do_clear_rebrief, normal pane: /clear then the rebrief, nothing else" || bad "do_clear_rebrief: $(cut -c1-60 "$T/rb.log" 2>/dev/null | tr '\n' '|')"

echo "== nothing is typed into a menu or a picker"
pane cm --mode insert --menu; cw "do_compact $SES:cm"
[ ! -s "$T/cm.log" ] && grep -q "/compact not seen submitted: a menu or dialog is open" "$T/cw.log" && ok "do_compact with a menu open: nothing submitted, logged" \
  || bad "menu: $(tr '\n' '|' < "$T/cm.log" 2>/dev/null) :: $(tail -1 "$T/cw.log" 2>/dev/null)"
pane cp --mode insert --picker; cw "do_clear_rebrief $SES:cp"
[ ! -s "$T/cp.log" ] && grep -q "clear-rebrief: /clear not seen submitted" "$T/cw.log" && ok "do_clear_rebrief with a picker: nothing submitted, rebrief not typed" \
  || bad "picker: $(tr '\n' '|' < "$T/cp.log" 2>/dev/null)"

echo "== a draft cleared to make room is logged; a nudge never wipes one"
pane cd --mode insert --box "half a draft"; cw "do_compact $SES:cd"
[ "$(cat "$T/cd.log" 2>/dev/null)" = "/compact $PRESERVE_TEXT" ] && grep -q "/compact cleared typed text from the box first: \[half a draft\]" "$T/cw.log" \
  && ok "do_compact over a draft: the draft is logged, never submitted" || bad "draft: $(cut -c1-60 "$T/cd.log" 2>/dev/null | tr '\n' '|') :: $(tail -1 "$T/cw.log")"
pane nd --mode insert --box "half a draft"; cw "do_nudge $SES:nd 72"
[ ! -s "$T/nd.log" ] && [ "$(command tmux -L "$SOCK" capture-pane -p -t "$SES:nd" | grep -c 'half a draft')" -ge 1 ] \
  && grep -q "nudge not sent: the box holds typed text: half a draft" "$T/cw.log" && ok "do_nudge over a draft: refused and logged, the draft is still there" \
  || bad "nudge: $(tr '\n' '|' < "$T/nd.log" 2>/dev/null) :: $(tail -1 "$T/cw.log")"

echo "== every clearing ti_send in the watchdog logs what it discarded"
sites=0; unlogged=""
while IFS=: read -r ln _; do
  sites=$((sites + 1))
  grep -qE '^[^#]*\$\{?TI_DISCARDED' <<<"$(sed -n "$((ln + 1))p" "$SRC/bin/compaction-watchdog.sh")" || unlogged="$unlogged $ln"
done < <(grep -nE '^[^#]*ti_send [^#]* clear; ' "$SRC/bin/compaction-watchdog.sh")
[ "$sites" -ge 6 ] && [ -z "$unlogged" ] && ok "all $sites clearing sites log TI_DISCARDED on the next line" || bad "sites=$sites unlogged:$unlogged"

[ "$fail" = 0 ] && echo "compaction-typing-observed.test: PASS ($n)" || { echo "compaction-typing-observed.test: FAIL"; exit 1; }

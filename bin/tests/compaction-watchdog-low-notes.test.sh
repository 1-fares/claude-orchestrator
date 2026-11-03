#!/usr/bin/env bash
# compaction-watchdog-low-notes.test.sh: three findings from a review of the compaction watchdog:
# 1. the probe-blind bus line prints the footer value once ("0% until auto-compact.", not "...auto-compact0.") and
#    "none" only when the footer shows nothing;
# 2. of several "/<window> tokens (NN%)" total lines on a pane, the percentage and the window both come from the one
#    with the most used tokens, so a quoted smaller total cannot lower the read;
# 3. only COMPACT_TEST_SOURCE=1 stops the file after its function definitions; a stray 0 does not.
# Functions only (COMPACT_TEST_SOURCE=1), no tmux, no bus: the bus line goes to a sink file.
# SRC=<engine tree> runs that tree's code (the red check).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export NOTIFY_SINK="$TD/notify-sink" WATCH_ALERT_SINK="$TD/watch-sink"
fail=0; n=0
ok()  { n=$((n+1)); echo "  ok   $1"; }
bad() { n=$((n+1)); fail=1; echo "  FAIL $1"; }
run() { # run <snippet>: with the watchdog's functions loaded
  env -u COMPACT_PRESERVE TEAM_DIR="$TD" TEAM_RUN_ID=testrun COMPACT_TEST_SOURCE=1 COMPACT_SOCKET=no-such-socket \
    COMPACT_SESSION=s COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" \
    COMPACT_HEALTH_DIR="$TD/health" COMPACT_BUS_SINK="$TD/bus" COMPACT_BUS_SEND="$TD/no-sender" \
    COMPACT_SETTINGS_FILE="${SETFILE:-$TD/no-settings.json}" COMPACT_PROBE_FAIL_ALARM=3 COMPACT_BLIND_BUS_EVERY=1 \
    bash -c '. "$0" >/dev/null 2>&1; eval "$1"' "$SRC/bin/compaction-watchdog.sh" "$1" 2>/dev/null
}

echo "== 1: the footer value is printed once"
: > "$TD/bus"; run 'blind_bus_notice w1 3 0 "  ⏵⏵ bypass permissions on · 0% until auto-compact"'
foot="$(grep -o 'pane footer: [^.]*\.' "$TD/bus" | head -1)"
[ "$foot" = "pane footer: 0% until auto-compact." ] && ok "footer 0%: [$foot]" || bad "footer 0%: [$foot] :: $(head -c 300 "$TD/bus")"
: > "$TD/bus"; run 'blind_bus_notice w1 3 0 "  ⏵⏵ bypass permissions on · 7% until auto-compact"'
foot="$(grep -o 'pane footer: [^.]*\.' "$TD/bus" | head -1)"
[ "$foot" = "pane footer: 7% until auto-compact." ] && ok "footer 7%: [$foot]" || bad "footer 7%: [$foot]"
: > "$TD/bus"; run 'blind_bus_notice w1 3 0 "  ⏵⏵ bypass permissions on"'
foot="$(grep -o 'pane footer: [^.]*\.' "$TD/bus" | head -1)"
[ "$foot" = "pane footer: none." ] && ok "no footer value: [$foot]" || bad "no footer value: [$foot]"
[ -s "$TD/bus" ] || bad "harness: no bus line was written at all"

echo "== 2: the total line with the most used tokens wins"
pane=$'  ⛁ System prompt: 2.5k tokens (0.2%)\n  60k/500k tokens (12%)\n  > quoted: "10k/100k tokens (10%)"'
got="$(P="$pane" run 'printf "%s\n" "$P" | parse_context_pct; printf " "; printf "%s\n" "$P" | context_denominator')"
[ "$got" = "12 500000" ] && ok "real total above a quoted smaller one: 12% of 500000" || bad "quoted below: got [$got], want [12 500000]"
pane2=$'  > quoted: "10k/100k tokens (10%)"\n  60k/500k tokens (12%)'
got="$(P="$pane2" run 'printf "%s\n" "$P" | parse_context_pct; printf " "; printf "%s\n" "$P" | context_denominator')"
[ "$got" = "12 500000" ] && ok "real total below a quoted smaller one: 12% of 500000" || bad "quoted above: got [$got]"
pane3=$'  931.6k/1m tokens (93%)'
got="$(P="$pane3" run 'printf "%s\n" "$P" | parse_context_pct; printf " "; printf "%s\n" "$P" | context_denominator')"
[ "$got" = "93 1000000" ] && ok "one total line: unchanged (93% of 1000000)" || bad "single line: got [$got]"
got="$(P="no total here" run 'printf "%s\n" "$P" | context_denominator')"
[ -z "$got" ] && ok "no total line: no denominator" || bad "no total line: got [$got]"
# End to end with the setting: 60k of a 150000 window is 40%, and the quoted 10%-of-100k line must not hold it at 12.
printf '{"autoCompactWindow": 150000}\n' > "$TD/settings.json"
got="$(P="$pane" SETFILE="$TD/settings.json" run 'rescale_pct "$(printf "%s\n" "$P" | parse_context_pct)" w1 "$(printf "%s\n" "$P" | context_denominator)"')"
[ -n "$got" ] && [ "$got" -ge 12 ] 2>/dev/null && ok "rescaled read is never below the real total's 12% (got $got)" || bad "rescale: got [$got]"

echo "== 3: only COMPACT_TEST_SOURCE=1 stops the file early"
for v in 1 0 yes; do
  out="$(env -i PATH="$PATH" HOME="$TD" TEAM_DIR="$TD" COMPACT_TEST_SOURCE="$v" bash -c '
    guard="$(sed -n "/^if \[ .*COMPACT_TEST_SOURCE/,/^fi/p" "$0")"
    f() { eval "$guard"; echo PASSED-GUARD; }; f' "$SRC/bin/compaction-watchdog.sh" 2>&1)"
  case "$v" in
    1) [[ "$out" != *PASSED-GUARD* ]] && ok "COMPACT_TEST_SOURCE=1: stops at the guard" || bad "=1 did not stop: $out" ;;
    *) [[ "$out" == *PASSED-GUARD* ]] && ok "COMPACT_TEST_SOURCE=$v: the daemon goes on" || bad "=$v stopped the daemon: $out" ;;
  esac
done

[ "$fail" = 0 ] && echo "compaction-watchdog-low-notes.test: PASS ($n)" || { echo "compaction-watchdog-low-notes.test: FAIL"; exit 1; }

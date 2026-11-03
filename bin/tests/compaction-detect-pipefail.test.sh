#!/usr/bin/env bash
# compaction-detect-pipefail.test.sh: _ceiling_state must read a pane holding the
# watchdog's own /context render (signature on top, the near-full banner, a long tail) as healthy every time. Under
# pipefail, `printf | _context_render_present` let grep's early exit SIGPIPE printf, and the render read as absent
# (warn: a forced /compact). Drives the path many times and counts wrong reads. Pure; no tmux, no live surface.
# COMPACT_DETECT_LIB points it at another copy of the library (the red-first run against the unfixed file).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null
. "${COMPACT_DETECT_LIB:-$repo/bin/lib/compaction-detect.sh}"
REPS="${COMPACT_DETECT_REPS:-2000}"
fail=0; ok(){ printf '  ok   %s\n' "$1"; }; no(){ printf '  FAIL %s\n' "$1"; fail=1; }

# render <tail-lines>: the probe's /context render as it sits on a pane, signature first, banner, then a tail
render() {
  printf ' Context Usage\n ⛁ System prompt: 2.7k tokens (0.5%%)\n ⚠ Context is 96%% full\n'
  printf '   Autocompact will trigger soon, which discards older messages.\n'
  for ((i = 0; i < $1; i++)); do printf '   ⛁ Messages: 31.2k tokens (6.2%%) row %d of the category table\n' "$i"; done
}

echo "1. fixtures: the render is a render, and the banner alone is a warning"
eq() { [ "$2" = "$3" ] && ok "$1 ($2)" || no "$1: expected [$3], got [$2]"; }
eq "a render with the banner, short" "$(render 3 | _ceiling_state)" ""
eq "the banner without a render" "$(printf ' ⚠ Context is 96%% full\n' | _ceiling_state)" "warn"

# the long render loses every read, so a tenth of the reps is enough there (each rep moves 263 KB)
for n in 200 4000; do
  t="$(render "$n")"; reps=$REPS; [ "$n" -gt 200 ] && reps=$((REPS / 10))
  echo "2. $reps reads of a render with a ${#t}-byte text: never warn"
  wrong=0
  for ((r = 0; r < reps; r++)); do [ -z "$(printf '%s' "$t" | _ceiling_state)" ] || wrong=$((wrong + 1)); done
  [ "$wrong" = 0 ] && ok "0/$reps wrong reads" || no "$wrong/$reps wrong reads (render read as absent -> warn)"
done

# 3. the other direction: a REAL near-full banner at the top of a long pane, with no render under it, must warn.
# Piping that long text into the banner check let grep's early exit SIGPIPE the producer, and the banner read as
# absent: this row fails every time on the pipe, with no load needed.
banner_long() { printf ' ⚠ Context is 96%% full\n'; for ((i = 0; i < $1; i++)); do printf '   line %d of ordinary pane output\n' "$i"; done; }
t="$(banner_long 4000)"; reps=$((REPS / 10)); missed=0
echo "3. $reps reads of a near-full banner on a ${#t}-byte pane with no render: always warn"
for ((r = 0; r < reps; r++)); do [ "$(printf '%s' "$t" | _ceiling_state)" = warn ] || missed=$((missed + 1)); done
[ "$missed" = 0 ] && ok "0/$reps missed" || no "$missed/$reps missed (banner read as absent)"

echo
[ "$fail" = 0 ] && echo "compaction-detect-pipefail: PASS" || { echo "compaction-detect-pipefail: FAIL"; exit 1; }

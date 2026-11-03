#!/usr/bin/env bash
# tmux-input-real-screens.test.sh: bin/lib/tmux-input.sh reads screens captured from a REAL claude 2.1.312 pane
# (capture-pane -e, bin/tests/fixtures/tmux-input/, 2026-11-02; the work-dir path sanitised). The real box mark is
# `❯` + U+00A0, which an earlier fake pane did not draw, so every send failed on a real pane while the fake suite was
# green. Derived from real captures: queued-placeholder (the placeholder text), menu-above-box (the menu rows measured
# after /clear), transcript-keys-no-reply (transcript-keys-idle without the reply), usage-drawing (usage-dialog before
# its Esc row is drawn). usage-tall-no-footer is real: a drawn /usage taller than the 50-row pane, its Esc row off
# screen. Edited for publication, same shape and columns: the time zone restated as UTC (the three usage captures and
# transcript-keys-idle); slash-autocomplete's last two rows are the built-in /memory and /help; permissions-dialog's
# allow list names built-in tools; the plugin row of the three usage captures is example-plugin. Everything else is
# byte for byte.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX="$repo/bin/tests/fixtures/tmux-input"
. "$repo/bin/lib/tmux-input.sh"
SCREEN=""
ti_tmux() { [ "$1" = capture-pane ] && cat "$FX/$SCREEN.raw"; }
fail=0; n=0
grep -q $'❯\xc2\xa0' "$FX/insert-empty.raw" || { echo "tmux-input-real-screens.test: FAIL (fixture lost its U+00A0; the test would prove nothing)"; exit 1; }

# fixture  has_box  insert  menu  text
while IFS='|' read -r fx box ins menu text; do
  SCREEN="$fx"; n=$((n+1))
  _ti_scan x
  got="$TI_HAS_BOX|$TI_INSERT|$TI_MENU|$TI_TEXT"
  if [ "$got" = "$box|$ins|$menu|$text" ]; then echo "  ok   $fx: box=$box insert=$ins menu=$menu text=[$text]"
  else fail=1; echo "  FAIL $fx: expected [$box|$ins|$menu|$text] got [$got]"; fi
done <<'ROWS'
insert-empty|1|1|0|
insert-text|1|1|0|leftover words
normal-text|1|0|0|leftover words
normal-empty|1|0|0|
insert-after-cc|1|1|0|
slash-autocomplete|1|1|0|/model
after-picker-escape|1|1|0|
queued-placeholder|1|1|0|
menu-above-box|1|1|1|
model-picker|0|0|1|
trust-menu-down|0|0|1|
usage-dialog|0|0|1|
transcript-keys-busy|1|1|0|
transcript-keys-idle|1|1|0|
transcript-keys-no-reply|1|1|0|
config-dialog|0|0|1|
permissions-dialog|0|0|1|
resume-dialog|0|0|1|
usage-drawing|0|0|0|
usage-tall-no-footer|0|0|0|
ROWS

# ti_send refuses a picker or a menu without sending a key, and returns 1 (not 2) so no caller types blind into it.
for fx in model-picker trust-menu-down menu-above-box usage-dialog config-dialog permissions-dialog resume-dialog; do
  SCREEN="$fx"; n=$((n+1)); sent=""
  ti_tmux() { case "$1" in capture-pane) cat "$FX/$SCREEN.raw" ;; send-keys) sent=1 ;; esac; }
  ti_send x "/context" clear; rc=$?
  if [ "$rc" = 1 ] && [ -z "$sent" ]; then echo "  ok   $fx: ti_send refused, rc 1, no key sent"
  else fail=1; echo "  FAIL $fx: ti_send rc $rc, key sent: ${sent:-no}"; fi
done

# With no box and no footer drawn, a claude pane is refused (rc 1, no key), and so is a pane
# whose command cannot be read or is not a shell; only a shell pane gets rc 2 (the caller may type blind).
PANECMD=""
ti_tmux() { case "$1" in capture-pane) cat "$FX/$SCREEN.raw" ;; display-message) [ -n "$PANECMD" ] && echo "$PANECMD" ;; send-keys) sent=1 ;; esac; }
for SCREEN in usage-drawing usage-tall-no-footer; do
for c in "claude 4242|1" "|1" "node 4242|1" "python3 4242|1" "bash $$|2" "zsh $$|2"; do
  PANECMD="${c%|*}"; want="${c#*|}"; n=$((n+1)); sent=""
  ti_send x "/context" clear; rc=$?
  if [ "$rc" = "$want" ] && [ -z "$sent" ]; then echo "  ok   $SCREEN, pane command [${PANECMD:-unreadable}]: rc $rc, no key sent"
  else fail=1; echo "  FAIL $SCREEN, pane command [${PANECMD:-unreadable}]: rc $rc (want $want), key sent: ${sent:-no}"; fi
done
done

# Transcript text naming menu keys ("Press Enter to continue", a footer-shaped bash output line)
# must not read as a menu, or an idle pane is refused every send. Here ti_send must get as far as typing.
for fx in transcript-keys-idle transcript-keys-no-reply; do
  SCREEN="$fx"; n=$((n+1)); sent=""
  ti_tmux() { case "$1" in capture-pane) cat "$FX/$SCREEN.raw" ;; send-keys) sent=1 ;; esac; }
  TI_SETTLE_TRIES=1 TI_KEY_PAUSE=0 ti_send x "/context" clear >/dev/null
  [ -n "$sent" ] && echo "  ok   $fx: not refused as a menu (keys sent)" || { fail=1; echo "  FAIL $fx: refused as a menu, nothing sent"; }
done

[ "$fail" = 0 ] && echo "tmux-input-real-screens.test: PASS ($n)" || { echo "tmux-input-real-screens.test: FAIL"; exit 1; }

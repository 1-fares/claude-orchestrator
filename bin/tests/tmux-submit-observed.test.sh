#!/usr/bin/env bash
# tmux-submit-observed.test.sh: tmux_submit (bin/lib/tmux-submit.sh, through bin/lib/tmux-input.sh) types a message
# into a Claude Code pane exactly once and exactly as given, in vim INSERT, vim NORMAL and non-vim; refuses a menu, a
# picker and a box holding a human's draft with zero keys; and a failed send removes only its own text.
# Real tmux on a private scratch server, bin/tests/lib/fake-cc-pane.py in the panes (it draws the box as a real
# claude 2.1.312 pane does and reads keys as vim does): no Claude, no role pane, no model call.
# SRC=<engine tree> runs that tree's bin/lib/tmux-submit.sh (the red check); the fake is always this tree's.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
FAKE="$repo/bin/tests/lib/fake-cc-pane.py"
command -v tmux >/dev/null || { echo "SKIP: no tmux"; exit 0; }
T="$(mktemp -d)"; SOCK="tso$$"; SES=t
export NOTIFY_SINK="$T/n.sink" WATCH_ALERT_SINK="$T/w.sink" TI_KEY_PAUSE=0.25 TI_SUBMIT_WAIT=0.9
SOCKPATH="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # kill-server leaves the socket file behind
trap 'command tmux -L "$SOCK" kill-server 2>/dev/null; rm -f "$SOCKPATH"; rm -rf "$T"' EXIT
command tmux -L "$SOCK" -f /dev/null new-session -d -s "$SES" -x 120 -y 30 -n base "sleep 600" 2>/dev/null \
  || { echo "SKIP: cannot start a scratch tmux server"; exit 0; }
fail=0; n=0
ok() { n=$((n+1)); echo "  ok   $1"; }
bad() { n=$((n+1)); fail=1; echo "  FAIL $1"; }

KEYS="$T/keys"; : > "$KEYS"
# The caller's tmux wrapper, as team-env's tmux() routes to the team socket; every send-keys is counted.
tmux() { [ "$1" = send-keys ] && echo "$*" >> "$KEYS"; command tmux -L "$SOCK" "$@"; }
. "$SRC/bin/lib/tmux-submit.sh"
tmux_submit() { _tmux_submit_via tmux "$@"; }
[ -f "$SRC/bin/lib/tmux-input.sh" ] || . "$repo/bin/lib/tmux-input.sh"   # the old tree has no reader; this one reads
ti_tmux() { "${TI_VIA:-tmux}" "$@"; }
pane() { # pane <name> <fake args...>
  local w="$1"; shift
  command tmux -L "$SOCK" new-window -d -t "$SES" -n "$w" "python3 '$FAKE' --log '$T/$w.log' $(printf '%q ' "$@")"
  sleep 0.5
}
keys() { wc -l < "$KEYS"; }
box() { ti_input_line "$SES:$1"; }
SHORT="Read the checkpoint and resume."
LONG="Read the checkpoint and resume. $(printf 'word %.0s' $(seq 1 120))END"; LONG="${LONG% }"
NUDGE="try again — the usage limit may have reset; resume your current unit where you left off"

echo "== exactly once, exactly as given"
pane ss --mode insert; tmux_submit "$SES:ss" "$SHORT" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/ss.log" 2>/dev/null)" = "$SHORT" ] && ok "short text, INSERT: once" || bad "short: rc $rc :: $(cut -c1-120 "$T/ss.log" 2>/dev/null)"
pane sl --mode insert; tmux_submit "$SES:sl" "$LONG" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/sl.log" 2>/dev/null)" = "$LONG" ] && ok "long text (a pasted block): once" || bad "long: rc $rc :: $(cut -c1-120 "$T/sl.log" 2>/dev/null)"
for m in normal nonvim; do
  pane "sn$m" --mode "$m"; tmux_submit "$SES:sn$m" "$NUDGE" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(cat "$T/sn$m.log" 2>/dev/null)" = "$NUDGE" ] && ok "a $m pane: the nudge arrives intact" \
    || bad "$m: rc $rc :: $(cut -c1-120 "$T/sn$m.log" 2>/dev/null)"
done
pane sq --mode insert --placeholder 'Press up to edit queued messages'; tmux_submit "$SES:sq" "$SHORT" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/sq.log" 2>/dev/null)" = "$SHORT" ] && ok "under a queued-message placeholder: once" \
  || bad "queued placeholder: rc $rc :: $(cut -c1-80 "$T/sq.log" 2>/dev/null)"
pane sk --mode insert --never-submit; tmux_submit "$SES:sk" "$SHORT" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "never submitted: exit 1" || bad "never submitted: rc $rc"

echo "== nothing is typed into a menu or a picker"
pane sm --mode insert --menu; k0="$(keys)"; tmux_submit "$SES:sm" "$SHORT" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(keys)" = "$k0" ] && [ ! -s "$T/sm.log" ] && ok "a menu open: zero keys, exit 1" || bad "menu: rc $rc, keys $(( $(keys) - k0 ))"
pane sp --mode insert --picker; k0="$(keys)"; tmux_submit "$SES:sp" "$SHORT" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(keys)" = "$k0" ] && [ ! -s "$T/sp.log" ] && ok "a picker in place of the box: zero keys, no blind fallback, exit 1" \
  || bad "picker: rc $rc, keys $(( $(keys) - k0 ))"

echo "== a human's draft is never appended to, submitted or deleted"
for mode in insert normal nonvim; do
  w="draft-$mode"; pane "$w" --mode "$mode" --box "half a draft"
  k0="$(keys)"; tmux_submit "$SES:$w" "try again" 2> "$T/$w.err"; rc=$?
  [ "$rc" = 1 ] && [ "$(keys)" = "$k0" ] && ok "$w: exit 1, zero keys" || bad "$w: rc $rc, keys $(( $(keys) - k0 ))"
  [ "$(box "$w")" = "half a draft" ] && ok "$w: the draft is untouched" || bad "$w: box now [$(box "$w")]"
  [ ! -s "$T/$w.log" ] && ok "$w: nothing submitted" || bad "$w: submitted :: $(tr '\n' '|' < "$T/$w.log")"
  grep -q 'not sent to .*: the box holds typed text: half a draft' "$T/$w.err" && ok "$w: the refusal is logged with the text" \
    || bad "$w: stderr :: $(cat "$T/$w.err")"
done
pane bc --mode insert --box bc
k0="$(keys)"; tmux_submit "$SES:bc" "/context" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(keys)" = "$k0" ] && ! grep -q 'bc/context' "$T/bc.log" 2>/dev/null \
  && ok "leftover 'bc': 'bc/context' is never submitted (exit 1, zero keys)" || bad "bc: rc $rc :: $(tr '\n' '|' < "$T/bc.log" 2>/dev/null)"

echo "== a failed send removes only its own text"
pane stuck --mode insert --never-submit
tmux_submit "$SES:stuck" "try again" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ -z "$(box stuck)" ] && ok "stuck: exit 1 and the box is empty again (its own text removed)" || bad "stuck: rc $rc, box [$(box stuck)]"
pane race --mode insert --never-submit
( sleep 1.5; command tmux -L "$SOCK" send-keys -t "$SES:race" -l "HUMAN" ) &
tmux_submit "$SES:race" "try again" 2> "$T/race.err"; rc=$?; wait
left="$(box race)"
[ "$rc" = 1 ] && [[ "$left" == *HUMAN* ]] && ok "a human typed during the failed send: HUMAN is still in the box [$left]" || bad "race: rc $rc, box [$left]"
grep -q 'left alone' "$T/race.err" && ok "race: the leftover is named on stderr" || bad "race: stderr :: $(cat "$T/race.err")"

[ "$fail" = 0 ] && echo "tmux-submit-observed.test: PASS ($n)" || { echo "tmux-submit-observed.test: FAIL"; exit 1; }

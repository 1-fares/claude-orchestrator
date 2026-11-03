#!/usr/bin/env bash
# tmux-submit.sh: shared verified-submit for typing a message into a Claude Code
# pane. Factored out of team-env.sh's tmux_submit so every injection path (the
# team scripts via team-env's tmux() wrapper, the compaction-watchdog via its
# own socket wrapper) uses ONE submit discipline instead of hand-rolled
# send-keys sequences.
#
# The typing itself is bin/lib/tmux-input.sh's ti_send, which acts only on what it
# reads on the screen: it refuses a menu or picker (an Enter there answers it), a
# claude pane with no input box, and a box that already holds someone's draft (a
# daemon never appends to, submits or deletes it); otherwise it forces INSERT (in
# vim NORMAL the text is read as commands: "try again" arrived as "gain"), types,
# waits until the box shows the text, and presses Enter until the box is empty (a
# long text collapses to a [Pasted text] block that needs a second Enter).
#
# _tmux_submit_via <tmux-cmd> <target> <message>
#   <tmux-cmd> is the caller's tmux wrapper (a function or binary name) that
#   already routes to the right socket/config; it is invoked as
#   `<tmux-cmd> send-keys ...` / `<tmux-cmd> capture-pane ...`.
#   Exit 0: the text was seen typed and then seen submitted, or typed into a shell
#   pane (no input box; the old blind recipe). Exit 1: refused or not seen
#   submitted; one line on stderr says why, and nothing was left in the box that
#   this call typed (a human's keys typed meanwhile are left alone and named).
#   Before this library the helper always returned 0, so every caller tolerates a
#   non-zero exit (`|| true`, an `if`, or a last command whose status is ignored).

# shellcheck source=bin/lib/tmux-input.sh
. "$(dirname "${BASH_SOURCE[0]}")/tmux-input.sh"
# tmux-input.sh reaches tmux through ti_tmux. TI_VIA names the caller's wrapper:
# _tmux_submit_via sets it for its own call; a script that calls ti_send directly
# sets it once (the compaction-watchdog sets TI_VIA=tmux_o).
ti_tmux() { "${TI_VIA:-tmux}" "$@"; }

_tmux_submit_via() {
  local TI_VIA="$1" _target="$2" _msg="$3" _rc
  ti_send "$_target" "$_msg"; _rc=$?
  if [ "$_rc" = 1 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tmux_submit: not sent to $_target: ${TI_REFUSED:-refused}" >&2
    return 1
  fi
  [ "$_rc" = 2 ] || return 0
  # No input box, in a pane that is positively a shell: type blind.
  "$TI_VIA" send-keys -t "$_target" -l "$_msg" 2>/dev/null || return 1
  "$TI_VIA" send-keys -t "$_target" Enter 2>/dev/null || true
  return 0
}

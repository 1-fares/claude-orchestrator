#!/usr/bin/env bash
# tmux-submit.sh: shared verified-submit for typing a message into a Claude Code
# pane. Factored out of team-env.sh's tmux_submit so every injection path (the
# team scripts via team-env's tmux() wrapper, the compaction-watchdog via its
# own socket wrapper) uses ONE submit discipline instead of hand-rolled
# send-keys sequences.
#
# Why the verification pass exists: a long typed message can collapse into a
# [Pasted text] block, where the first Enter only inserts a newline and a
# second Enter submits. The blind double-Enter (0.4s gap) covers the common
# case, but under host load 0.4s is too short and nudges were found sitting
# unsubmitted in the input line hours later (observed on post-hibernation
# panes, 2026-07-10). So after the double-Enter we capture the pane, check the
# input line actually emptied, and press Enter again (twice max) if not.
#
# _tmux_submit_via <tmux-cmd> <target> <message>
#   <tmux-cmd> is the caller's tmux wrapper (a function or binary name) that
#   already routes to the right socket/config; it is invoked as
#   `<tmux-cmd> send-keys ...` / `<tmux-cmd> capture-pane ...`.
#
# Verification rules, in order:
#   - capture fails or pane has no input prompt (❯): not a Claude pane we can
#     verify; treat as submitted.
#   - a modal dialog footer is on screen (Enter to confirm / Esc to cancel):
#     STOP without pressing Enter — the modal swallowed the input and another
#     Enter would confirm an arbitrary dialog option, not submit our text.
#   - input line empty, or only the dim autocomplete shadow: submitted.
#   - otherwise: press Enter once more and re-check (2 attempts).

_tmux_submit_via() {
  local _tm="$1" _target="$2" _msg="$3" _try _etxt _plain _iline _eline
  "$_tm" send-keys -t "$_target" -l "$_msg" 2>/dev/null || return 1
  "$_tm" send-keys -t "$_target" Enter 2>/dev/null || true
  sleep 0.4
  "$_tm" send-keys -t "$_target" Enter 2>/dev/null || true
  for _try in 1 2; do
    sleep 0.6
    _etxt="$("$_tm" capture-pane -e -t "$_target" -p 2>/dev/null)" || return 0
    [ -n "$_etxt" ] || return 0
    _plain="$(printf '%s' "$_etxt" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g')"
    printf '%s' "$_plain" | grep -aq '❯' || return 0
    if printf '%s' "$_plain" | tail -15 | grep -qiE 'Enter to confirm|Esc to cancel'; then
      return 0
    fi
    # Input line = content after the last prompt glyph, minus the UTF-8
    # non-breaking space Claude Code renders after ❯ and ASCII whitespace.
    _iline="$(printf '%s' "$_plain" | grep -a '❯' | tail -1 | sed -E 's/.*❯//' | sed $'s/\xc2\xa0//g' | tr -d '[:space:]')"
    [ -z "$_iline" ] && return 0
    # Dim (\e[2m / \e[0;2m) after the prompt = autocomplete shadow, not real text.
    _eline="$(printf '%s' "$_etxt" | grep -a '❯' | tail -1)"
    if printf '%s' "$_eline" | grep -qE $'\x1b\\[0?;?2m'; then return 0; fi
    "$_tm" send-keys -t "$_target" Enter 2>/dev/null || true
  done
  return 0
}

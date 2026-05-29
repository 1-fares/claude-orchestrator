#!/usr/bin/env bash
# watchdog-detect.sh: pure, stdin-based pane detectors used by api-watchdog.sh.
# Factored out so they can be unit-tested without a live tmux session or the
# daemon loop. No side effects, no tmux, no global writes.
#
# Callers must have these globals set before using _classify_text:
#   pattern_regex   ERE of API-stall error patterns (api-watchdog builds it
#                   from bin/api-watchdog.patterns)
#
# Provided:
#   BUSY_RE         markers that a spinner / active turn is on screen
#   VOLATILE_RE     per-second-volatile chrome stripped before fingerprinting
#   _classify_text  stdin pane text -> "active" | "stalled-api"
#   _is_busy_text   stdin pane text -> exit 0 iff a spinner is shown
#   _fingerprint_text stdin pane text -> stable hash of the non-volatile tail

# A spinner / active-turn marker is on screen. Shared by classify (busy => not
# api-stalled) and the stuck detector (busy + frozen => wedged).
BUSY_RE='esc to interrupt|Working…|Thinking|· ↓|tokens ·|[0-9]+ monitor'

# Per-second-volatile chrome that must be stripped before fingerprinting a pane,
# or the fingerprint changes every tick even when the role is wedged: the
# spinner line, its elapsed timer + token counter, the monitor status, and the
# rotating input-box placeholder.
VOLATILE_RE='esc to interrupt|Working|Thinking|for [0-9]+s|\([0-9]+m|\([0-9]+s|↓|tokens| monitor|-- INSERT --|⏵⏵|bypass permissions|^[[:space:]]*$|^❯'

# _classify_text: stdin = pane text -> echoes active | stalled-api
# "stalled-api" requires, on the visible bottom of the pane: no spinner, the
# Claude-TUI input marker '❯' rendered, and a configured error pattern in the
# recent output. Needs $pattern_regex set by the caller.
_classify_text() {
  local visible busy idle hit
  visible="$(cat)"
  busy="$(printf '%s' "$visible" | tail -25 | grep -ciE "$BUSY_RE")"
  if [ "$busy" -gt 0 ]; then echo "active"; return; fi
  idle="$(printf '%s' "$visible" | tail -8 | grep -c '❯' || true)"
  if [ "$idle" -eq 0 ]; then echo "active"; return; fi
  hit="$(printf '%s' "$visible" | tail -15 | grep -iE "${pattern_regex:-$^}" | head -1 || true)"
  if [ -n "$hit" ]; then echo "stalled-api"; return; fi
  echo "active"
}

# _is_busy_text: stdin = pane text -> exit 0 if a spinner / active turn is shown
_is_busy_text() { tail -25 | grep -qiE "$BUSY_RE"; }

# _fingerprint_text: stdin = pane text -> stable hash of the non-volatile tail.
# Strips the animated status chrome so the hash only changes on real progress
# (new assistant output, a new/finished tool call). A frozen pane => stable hash.
_fingerprint_text() {
  grep -avE "$VOLATILE_RE" | tail -n 40 | cksum | cut -d' ' -f1
}

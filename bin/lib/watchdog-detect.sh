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
#   AWAIT_RE        markers that an interactive prompt is awaiting human input
#   USAGE_RE        markers of the usage-limit dialog (auto-recoverable stall)
#   VOLATILE_RE     per-second-volatile chrome stripped before fingerprinting
#   _classify_text  stdin pane text ->
#                   "active" | "stalled-usage" | "stalled-api" | "awaiting-input"
#   _is_busy_text   stdin pane text -> exit 0 iff a spinner is shown
#   _is_awaiting_input_text stdin pane text -> exit 0 iff a prompt awaits a human
#   _is_usage_stall_text stdin pane text -> exit 0 iff the usage dialog is shown
#   _has_modal_dialog_text stdin pane text -> exit 0 iff a modal dialog is open
#   _fingerprint_text stdin pane text -> stable hash of the non-volatile tail

# A spinner / active-turn marker is on screen. Shared by classify (busy => not
# api-stalled) and the stuck detector (busy + frozen => wedged).
#
# Only true active-turn markers belong here. The "N monitor" count in the
# status bar (e.g. "⏵⏵ bypass permissions on · 1 monitor") is persistent chrome
# shown while idle too, so it is NOT a busy marker — including it made an idle
# role that legitimately holds at its prompt past the stuck threshold read as
# busy+frozen and get falsely flagged stuck. It stays in VOLATILE_RE (stripped
# from the fingerprint); a real wedge is still caught by "esc to interrupt"
# (shown for any in-flight tool call) plus a frozen token readout.
BUSY_RE='esc to interrupt|Working…|Thinking|· ↓|tokens ·'

# An interactive prompt is on screen AWAITING a human decision: a selection
# menu (AskUserQuestion, plan/permission prompts) or a yes/no confirmation. The
# session is not "busy" (no spinner) and not a plain idle prompt — it is BLOCKED
# until a human answers, and nothing in the run can proceed. Left unwatched this
# silently stalls the whole team: the orchestrator waiting on an operator
# decision reads as a healthy idle role. Matched on Claude Code's stable
# menu / confirmation chrome. 'Enter to confirm' is the footer of the modal
# dialog family (usage-limit, plan-upgrade, ...); a dialog that is not a usage
# stall (below, checked first) still blocks the session and must not read idle.
AWAIT_RE='Enter to select|Enter to confirm|Do you want to proceed|Would you like to proceed|Do you want to make this edit|Do you want to create'

# The USAGE-LIMIT dialog: the account ran out of usage/credits and Claude Code
# replaced the prompt with a modal ("Stop and wait for limit to reset / Add
# funds ... / Enter to confirm"). Unlike the AWAIT_RE prompts this IS
# auto-recoverable (Escape dismisses the modal; a later "try again" resumes the
# turn once usage returns), and unlike the API-stall patterns it shows no "API
# Error" text and its option line carries a '❯', so before this class existed
# it fell through every net and classified as healthy-idle "active" — three
# roles sat silently parked through a real usage outage (2026-07-10). Matched
# on the dialog's stable option/consequence lines, not the header wording.
USAGE_RE='wait for limit to reset|Add funds to continue with usage credits|usage limit reached|reached your usage limit'

# Per-second-volatile chrome that must be stripped before fingerprinting a pane,
# or the fingerprint changes every tick even when the role is wedged: the
# spinner line, its elapsed timer + token counter, the monitor status, and the
# rotating input-box placeholder.
VOLATILE_RE='esc to interrupt|Working|Thinking|for [0-9]+s|\([0-9]+m|\([0-9]+s|↓|tokens| monitor|-- INSERT --|⏵⏵|bypass permissions|^[[:space:]]*$|^❯'

# _classify_text: stdin = pane text -> echoes
#   active | stalled-usage | stalled-api | awaiting-input
# Precedence: a spinner means "busy" (active) and wins. Otherwise the
# usage-limit dialog means "stalled-usage" (auto-recoverable, so it must win
# over the generic awaiting-input class whose only remedy is paging a human).
# Otherwise a menu / confirmation prompt means "awaiting-input" (blocked on a
# human). Otherwise "stalled-api" requires the Claude-TUI input marker '❯'
# rendered plus a configured error pattern in the recent output. Else
# "active". Needs $pattern_regex set by the caller.
_classify_text() {
  local visible busy idle hit
  visible="$(cat)"
  busy="$(printf '%s' "$visible" | tail -25 | grep -ciE "$BUSY_RE")"
  if [ "$busy" -gt 0 ]; then echo "active"; return; fi
  if printf '%s' "$visible" | tail -15 | grep -qiE "$USAGE_RE"; then echo "stalled-usage"; return; fi
  if printf '%s' "$visible" | tail -15 | grep -qiE "$AWAIT_RE"; then echo "awaiting-input"; return; fi
  idle="$(printf '%s' "$visible" | tail -8 | grep -c '❯' || true)"
  if [ "$idle" -eq 0 ]; then echo "active"; return; fi
  hit="$(printf '%s' "$visible" | tail -15 | grep -iE "${pattern_regex:-$^}" | head -1 || true)"
  if [ -n "$hit" ]; then echo "stalled-api"; return; fi
  echo "active"
}

# _is_busy_text: stdin = pane text -> exit 0 if a spinner / active turn is shown
_is_busy_text() { tail -25 | grep -qiE "$BUSY_RE"; }

# _is_awaiting_input_text: stdin = pane text -> exit 0 iff an interactive prompt
# is awaiting a human decision (selection menu / confirmation).
_is_awaiting_input_text() { tail -15 | grep -qiE "$AWAIT_RE"; }

# _is_usage_stall_text: stdin = pane text -> exit 0 iff the usage-limit dialog
# (or its residue) is on screen.
_is_usage_stall_text() { tail -15 | grep -qiE "$USAGE_RE"; }

# _has_modal_dialog_text: stdin = pane text -> exit 0 iff a modal dialog is
# open (its footer is on screen). Recovery must send Escape to dismiss the
# modal before any typed nudge can reach the input line.
_has_modal_dialog_text() { tail -15 | grep -qiE 'Enter to confirm|Esc to cancel'; }

# _fingerprint_text: stdin = pane text -> stable hash of the non-volatile tail.
# Strips the animated status chrome so the hash only changes on real progress
# (new assistant output, a new/finished tool call). A frozen pane => stable hash.
_fingerprint_text() {
  grep -avE "$VOLATILE_RE" | tail -n 40 | cksum | cut -d' ' -f1
}

# _token_readout: stdin = pane text -> the most recent streaming token readout
# shown in the spinner (e.g. "↓ 34.4k tokens" / "↑ 46.0k tokens"), or empty if
# none is on screen. This advances while the model streams or THINKS but is
# frozen when wedged on a hung tool call, so it is the liveness signal that
# keeps a long legitimate think from being mistaken for a wedge. (The elapsed
# timer is NOT a liveness signal: it ticks even when wedged.)
_token_readout() {
  grep -oE '[↑↓] ?[0-9.]+[kKmM]? tokens' | tail -1
}

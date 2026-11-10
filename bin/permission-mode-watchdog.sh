#!/usr/bin/env bash
# permission-mode-watchdog.sh: keep every team pane in the permission mode the
# run was LAUNCHED with, and undo the drift silently instead of parking the run
# on a prompt only a human at a laptop can answer.
#
# Why (2026-08-25 incident): the orchestrator was repeatedly parked on
#
#     Auto mode classifier requires confirmation for this command.
#     4 consecutive actions were blocked.
#     Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No
#
# for a `gh pr merge` into dev. The api-watchdog escalated on every occurrence to
# the ntfy topic it is configured with, but the operator was away from a laptop,
# and a tmux selection menu cannot be answered from anywhere else. It happened SIX
# times that afternoon -- 14:43-15:59Z, 16:00-16:15Z, 16:18-16:30Z, 16:34-17:02Z,
# 17:03-17:21Z and 17:22-17:31Z -- about 158 minutes of run time blocked in total,
# not one bad moment. (An earlier version of this comment said "~30m" and "his
# phone": the first was one occurrence mistaken for all of them, the second was
# never established. The per-role log at audit/api-watchdog/orchestrator.log is
# the source for the timings above.)
#
# ROOT CAUSE, measured not assumed. Every session is spawned with
# --dangerously-skip-permissions (start-orchestrator.sh:31, launch-team.sh:54,
# add-role.sh:55). At the time of the incident the NINE role panes read
# "⏵⏵ bypass permissions on" and the orchestrator pane read "⏵⏵ auto mode on" —
# same flag, same settings.json, same box, same user. A control session spawned
# with the identical flag in the identical directory came up in bypass, so the
# orchestrator was NOT born in auto mode: it was demoted at runtime. Claude Code
# cycles the permission mode on shift+tab, and the orchestrator pane is the one
# pane humans and daemons type into all day. One stray shift+tab silently
# downgrades the session for the rest of its life, and NOTHING reported it: the
# 2026-08-22 handoff recorded the orchestrator "running in auto mode from the
# same flag" as an unexplained curiosity three days before it cost a run.
#
# In bypass mode the classifier gate does not arm at all, so this class of
# prompt simply stops happening once the mode is held. That is the fix: hold the
# mode, do not get better at answering the prompt.
#
# The observed cycle (measured on Claude Code 2.1.239, 5 states):
#   bypass permissions -> auto mode -> plan -> accept edits -> normal -> bypass
# `plan` and `normal` render no "⏵⏵ <mode> on" marker at all, so an unreadable
# mode is treated as "not bypass" and cycled onward rather than trusted.
#
# What it does each cycle, per pane:
#   - reads the mode off the status line;
#   - if it already matches the expected mode, does nothing;
#   - otherwise presses shift+tab (tmux `BTab`) up to MAX_PRESSES times,
#     re-reading after every press, and stops the moment the mode is back.
#
# Two guards, both load-bearing:
#   1. NEVER press shift+tab while a selection menu is open. In a menu those
#      keystrokes move the selection instead of the mode, which is how an
#      auto-recovery turns into an accidental "Yes" on a destructive action.
#   2. The ONLY prompt this daemon dismisses is the auto-mode classifier gate,
#      identified by its own banner text. Escape CANCELS that prompt — it never
#      confirms it — and the session then retries the same command under the
#      restored mode. Every other prompt (AskUserQuestion, a real permission
#      request, the `rm` guard that correctly fired on 2026-08-03) is left
#      untouched for the api-watchdog to escalate exactly as it does today.
#      This daemon must never become a machine that clicks "Yes" on prompts it
#      does not understand.
#
# Pure shell. Makes no Claude API call, so a rate limit or an auth death cannot
# stop it recovering the team.
#
# Env:
#   PERMISSION_MODE_WATCHDOG_DISABLED=1  do not run (exit 0)
#   PMW_EXPECTED=<text>   mode to hold (default "bypass permissions")
#   PMW_INTERVAL=30       seconds between sweeps
#   PMW_MAX_PRESSES=6     shift+tab presses before giving up on a pane
#   PMW_UNREADABLE_ALARM=10  consecutive unreadable sweeps -> marker + push
#   PMW_SETTLE=2          seconds to let the status line repaint after a press
#   PMW_ONESHOT=1         run ONE sweep and exit (used by the test suite)
#   PMW_SOCKET/PMW_SESSION  tmux -L socket / session (engine passes TEAM_TMUX/TEAM_SESSION)
#   PMW_LOG=<path>        audit log (default $TEAM_DIR/permission-mode-watchdog.log)
#   PMW_ABSENT_EXIT=10    consecutive sweeps with no tmux session before the daemon
#                         exits (the team is gone; a relaunch starts a new one)
#   NTFY_URL              operator push target, read by bin/lib/notify.sh (the daemon
#                         notifies through it, class action; unset = log only)

set -uo pipefail
# Original invocation args, captured before any parsing, so self-reload can re-exec
# this daemon with the same flags (bin/lib/self-reload.sh).
_SR_ORIG_ARGS=("$@")

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"
# Self-reload: re-exec when this file or a lib it sources changes on disk, so a synced
# fix takes effect without a restart. 2026-09-02: this daemon kept running 24 August
# code for nine hours after the fix landed, because only api-watchdog reloaded itself.
# shellcheck source=bin/lib/self-reload.sh
. "$repo/bin/lib/self-reload.sh"
self_reload_init "$0" "$repo/bin/team-env.sh" "$repo/bin/lib/tmux-submit.sh" "$repo/bin/lib/tmux-input.sh" "$repo/bin/lib/self-reload.sh" "$repo/bin/lib/notify.sh"
# The operator is reached only through bin/lib/notify.sh (class, mute, dedupe, decision
# log). It needs TEAM_DIR only, so it also works without a TEAM_RUN_ID.
# shellcheck source=bin/lib/notify.sh
. "$repo/bin/lib/notify.sh"
NOTIFY_SOURCE=permission-mode-watchdog

[ "${PERMISSION_MODE_WATCHDOG_DISABLED:-0}" = "1" ] && exit 0

SOCKET="${PMW_SOCKET:-$TEAM_TMUX}"
SESSION="${PMW_SESSION:-$TEAM_SESSION}"
EXPECTED="${PMW_EXPECTED:-bypass permissions}"
INTERVAL="${PMW_INTERVAL:-30}"
MAX_PRESSES="${PMW_MAX_PRESSES:-6}"
UNREADABLE_ALARM="${PMW_UNREADABLE_ALARM:-10}"
SETTLE="${PMW_SETTLE:-2}"
ABSENT_EXIT="${PMW_ABSENT_EXIT:-10}"
LOG="${PMW_LOG:-$TEAM_DIR/permission-mode-watchdog.log}"
MARKER_DIR="$TEAM_DIR/health"

mkdir -p "$(dirname "$LOG")" "$MARKER_DIR" 2>/dev/null || true

iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(iso)" "$*" >> "$LOG"; }

tmux_t() { command tmux -L "$SOCKET" "$@"; }

# The auto-mode classifier gate, matched on its OWN banner rather than on the
# generic "Do you want to proceed" footer that every permission prompt shares.
# Narrow on purpose: this is the one prompt we are allowed to dismiss, because
# it is an artefact of the drift and not a real danger signal.
CLASSIFIER_RE='Auto mode classifier requires confirmation|Blocked by classifier'

# Any interactive prompt awaiting a human. Kept in sync with watchdog-detect.sh's
# AWAIT_RE; duplicated rather than sourced so this daemon has no dependency that
# could break its recovery path.
AWAIT_RE='Enter to select|Enter to confirm|Do you want to proceed|Would you like to proceed|Do you want to make this edit|Do you want to create'

pane_text() { tmux_t capture-pane -t "$1" -p 2>/dev/null; }

# Read the mode off the status line. Empty output means "could not read it",
# which includes the two modes that render no marker (plan, normal). Callers
# must treat empty as drift, never as success.
pane_mode() {
  printf '%s' "$1" | grep -oE '⏵⏵ [a-z ]+ on' | tail -1 \
    | sed -E 's/^⏵⏵ //; s/ on$//'
}

# Case-insensitive, as watchdog-detect.sh matches the same AWAIT_RE.
has_menu()       { grep -qiE "$AWAIT_RE" <<<"$1"; }
has_classifier() { grep -qE "$CLASSIFIER_RE" <<<"$1"; }

# Cycle one pane back to EXPECTED. Returns 0 once the status line reads the
# expected mode, 1 if MAX_PRESSES presses did not get there.
restore_mode() {
  local target="$1" name="$2" n txt mode
  for (( n=1; n<=MAX_PRESSES; n++ )); do
    tmux_t send-keys -t "$target" BTab 2>/dev/null || return 1
    sleep "$SETTLE"
    txt="$(pane_text "$target")"
    mode="$(pane_mode "$txt")"
    if [ "$mode" = "$EXPECTED" ]; then
      log "[$name] RESTORED to '$EXPECTED' after $n shift+tab press(es)"
      return 0
    fi
  done
  return 1
}

sweep_pane() {
  local target="$1" name="$2" txt mode

  txt="$(pane_text "$target")"
  [ -n "$txt" ] || return 0
  mode="$(pane_mode "$txt")"

  # Already correct: nothing to do, and say nothing (silence is the normal case).
  if [ "$mode" = "$EXPECTED" ]; then
    rm -f "$MARKER_DIR/permission-mode-$name.md" "$MARKER_DIR/.pmw-unreadable-$name" 2>/dev/null
    return 0
  fi

  if has_menu "$txt"; then
    if has_classifier "$txt"; then
      # The prompt only exists because the mode drifted. Escape CANCELS it (no
      # action is confirmed), then we put the mode back and let the session
      # retry the same command without a gate in the way.
      log "[$name] classifier gate on screen in mode '${mode:-unreadable}'; sending Escape (cancel, not confirm)"
      tmux_t send-keys -t "$target" Escape 2>/dev/null || true
      sleep "$SETTLE"
      txt="$(pane_text "$target")"
      if has_menu "$txt"; then
        log "[$name] classifier gate SURVIVED Escape; leaving it for the api-watchdog to escalate"
        return 0
      fi
      # Re-read: the status line only repaints once the modal is gone, and the
      # mode we must act on is the one AFTER the dismissal, not before it.
      mode="$(pane_mode "$txt")"
      [ "$mode" = "$EXPECTED" ] && { rm -f "$MARKER_DIR/.pmw-unreadable-$name" 2>/dev/null; return 0; }
    else
      # A real prompt. Not ours to answer, and pressing shift+tab into an open
      # menu would move the selection. Leave it entirely alone.
      log "[$name] drifted to '${mode:-unreadable}' but a non-classifier prompt is open; not touching the pane"
      return 0
    fi
  fi

  # UNREADABLE IS NOT DRIFT. Two of the five modes (plan, normal) render no
  # "⏵⏵ <mode> on" marker, and a full-screen view or a repaint in flight hides it
  # too. Cycling on a mode we cannot see is pressing keys we do not understand:
  # it can walk a pane that was already correct into the wrong mode. So we skip
  # the sweep and try again in $INTERVAL. Persistent unreadability is itself
  # reported, because on this team silence has never been allowed to stand in for
  # coverage.
  local ucount_f="$MARKER_DIR/.pmw-unreadable-$name"
  if [ -z "$mode" ]; then
    local uc; uc="$(( $(cat "$ucount_f" 2>/dev/null || echo 0) + 1 ))"
    echo "$uc" > "$ucount_f"
    if [ "$uc" -eq "$UNREADABLE_ALARM" ]; then
      log "[$name] mode UNREADABLE for $uc consecutive sweeps; not cycling blind"
      {
        echo "# Permission mode unreadable — role '$name'"
        echo
        echo "_$(iso)_ — the pane has shown no '⏵⏵ <mode> on' status line for"
        echo "$uc consecutive sweeps, so the watchdog cannot confirm it is in"
        echo "'$EXPECTED' and will not cycle a mode it cannot see."
        echo
        echo "Check it by hand: ${TEAM_RUN_ID:+TEAM_RUN_ID=$TEAM_RUN_ID }bin/attach.sh"
      } > "$MARKER_DIR/permission-mode-$name.md"
      notify_operator action "permission mode unreadable: $name" \
        "[orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' has not shown a permission-mode status line for $uc sweeps; check it by hand (see $MARKER_DIR/permission-mode-$name.md)"
    fi
    return 0
  fi
  rm -f "$ucount_f" 2>/dev/null

  log "[$name] permission mode is '$mode', expected '$EXPECTED'; restoring"
  if restore_mode "$target" "$name"; then
    rm -f "$MARKER_DIR/permission-mode-$name.md" 2>/dev/null
    return 0
  fi

  # Could not get it back. Make it loud: this is the exact silent-drift failure
  # the daemon exists to prevent, so it must never fail quietly.
  local marker="$MARKER_DIR/permission-mode-$name.md"
  if [ ! -f "$marker" ]; then
    {
      echo "# Permission mode stuck — role '$name'"
      echo
      echo "_$(iso)_ — pane is in mode '${mode:-unreadable}', expected '$EXPECTED'."
      echo "$MAX_PRESSES shift+tab presses did not restore it."
      echo
      echo "Until this is fixed the session can stop on permission prompts that"
      echo "nobody can answer remotely. Attach and cycle it by hand:"
      echo "  ${TEAM_RUN_ID:+TEAM_RUN_ID=$TEAM_RUN_ID }bin/attach.sh    # then shift+tab to 'bypass permissions on'"
    } > "$marker"
    log "[$name] RESTORE FAILED after $MAX_PRESSES presses; wrote $marker"
    notify_operator action "permission mode stuck: $name" \
      "[orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' is in '${mode:-unreadable}', expected '$EXPECTED'; prompts may block the run (see $marker)"
  fi
  return 1
}

# sweep_all: exit 3 when the session does not exist, else 0.
sweep_all() {
  tmux_t has-session -t "$SESSION" 2>/dev/null || return 3
  while IFS=$'\t' read -r widx wname; do
    [ -n "${widx:-}" ] || continue
    sweep_pane "${SESSION}:${widx}" "${wname:-w$widx}" || true
  done < <(tmux_t list-windows -t "$SESSION" -F '#{window_index}	#{window_name}' 2>/dev/null)
  return 0
}

# One sweep and out: lets the test suite drive the real script rather than a
# re-implementation of it, which is how the api-watchdog guards regressed
# unnoticed for 28 days (see bin/tests/h9-stuck-path-modal-guard.test.sh).
if [ "${PMW_ONESHOT:-0}" = "1" ]; then sweep_all; exit 0; fi

log "permission-mode-watchdog started (socket=$SOCKET session=$SESSION expected='$EXPECTED' interval=${INTERVAL}s)"

# Exit once the team session has been gone for ABSENT_EXIT consecutive sweeps: the
# loop otherwise ran forever after the team (and often $TEAM_DIR) was gone. A
# relaunch starts a new daemon (ensure_team_daemons, and tmux-watchdog while the
# session is up).
absent=0
while :; do
  self_reload_check "$0" ${_SR_ORIG_ARGS[@]+"${_SR_ORIG_ARGS[@]}"}
  if sweep_all; then
    absent=0
  else
    absent=$((absent + 1))
    if [ "$absent" -ge "$ABSENT_EXIT" ]; then
      log "session $SESSION absent for $absent consecutive sweeps; exiting"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done

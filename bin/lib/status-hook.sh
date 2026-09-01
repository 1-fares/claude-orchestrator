#!/usr/bin/env bash
# status-hook.sh: ONE call site for "the team can no longer work" events.
#
# Why. Every daemon here already knows when the team stops: api-watchdog sees the
# usage-limit dialog and the operator prompt, compaction-watchdog sees a pane that
# will not compact. Each tells the OPERATOR (ntfy) and nobody else. The people who
# depend on the team's output learn of it by asking "are you down?" in chat, hours
# later. Measured: 2026-08-25 the orchestrator sat ~90 min on a permission prompt
# while the product owner asked three times; 2026-08-30/31 the account was walled
# 32 hours and nobody outside the operator was told. Silence read as work.
#
# What. `status_hook <event> <role> <detail>` runs the project-supplied executable
# $TEAM_STATUS_HOOK (resolved by team-env.sh) with those three arguments, in the
# background under a timeout, deduped per (event, role). The hook decides who is
# told and where (a chat channel, a status page, a ticket); this engine names no
# platform. Unset or missing hook = silent no-op, always. Every decision this
# function takes is appended to $TEAM_DIR/reports/status-hook.log so the question
# "was anyone told?" has an answer that is not somebody's memory.
#
# Events (the vocabulary a hook may expect; detail is free text for humans):
#   usage-wall         role parked on the usage-limit dialog
#   usage-recovered    role worked again after a usage wall (confirmed, not a blip)
#   awaiting-operator  role blocked on an interactive prompt past AWAIT_OPERATOR_SEC
#   operator-answered  that prompt cleared
#   wedged             role hung or gave up on an API error; a human/orchestrator was asked to act
#   compact-stuck      forced /compact left the pane near-full COMPACT_FORCE_ESCALATE times
#   recovered          the wedged / compact-stuck condition cleared
#
# A recovery event clears the dedupe of its counterpart, so the next real wall or
# wedge fires again instead of being swallowed by a stale timestamp.
#
# Env:
#   TEAM_STATUS_HOOK            executable path (team-env.sh resolves it)
#   STATUS_HOOK_DEDUPE_SEC=1800 min seconds between two fires of the same (event, role)
#   STATUS_HOOK_TIMEOUT_SEC=30  hook wall-clock limit; a hung hook never blocks a daemon

_sh_log() {
  local log="$1"; shift
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$log" 2>/dev/null || true
}

_sh_state() { printf '%s/health/status-hook.%s.%s.last' "${TEAM_DIR:-.}" "$1" "$2"; }

# status_hook_reset <event> <role>: forget the dedupe timestamp for (event, role).
status_hook_reset() { rm -f "$(_sh_state "$1" "$2")" 2>/dev/null || true; }

status_hook() {
  local event="${1:-}" role="${2:-}" detail="${3:-}"
  local hook="${TEAM_STATUS_HOOK:-}"
  local log="${TEAM_DIR:-.}/reports/status-hook.log"
  [ -n "$event" ] && [ -n "$role" ] || return 0
  [ -n "$hook" ] || return 0
  if [ ! -x "$hook" ]; then
    _sh_log "$log" "SKIP $event $role: hook not executable: $hook"
    return 0
  fi
  # A recovery clears its counterpart's dedupe so the next episode is reported.
  case "$event" in
    usage-recovered)   status_hook_reset usage-wall "$role" ;;
    operator-answered) status_hook_reset awaiting-operator "$role" ;;
    recovered)         status_hook_reset wedged "$role"; status_hook_reset compact-stuck "$role" ;;
  esac
  local dd="${STATUS_HOOK_DEDUPE_SEC:-1800}" state now last
  state="$(_sh_state "$event" "$role")"
  now=$(date +%s)
  last=$(cat "$state" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$dd" ]; then
    _sh_log "$log" "DEDUPE $event $role (last fire $((now - last))s ago < ${dd}s)"
    return 0
  fi
  mkdir -p "$(dirname "$state")" 2>/dev/null || true
  echo "$now" > "$state" 2>/dev/null || true
  _sh_log "$log" "FIRE $event $role: $detail"
  (
    if timeout "${STATUS_HOOK_TIMEOUT_SEC:-30}" "$hook" "$event" "$role" "$detail" >>"$log" 2>&1; then
      _sh_log "$log" "OK $event $role"
    else
      _sh_log "$log" "FAIL rc=$? $event $role (hook=$hook)"
    fi
  ) &
  return 0
}

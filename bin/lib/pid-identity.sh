#!/usr/bin/env bash
# pid-identity.sh -- sourced; decides whether a pid read from a pidfile is safe to signal.

# proc_pid_is_run_daemon <pid> <script-glob>... -> 0 only if <pid> is live, the program it runs IS
# one of the scripts (argv[0], or the first non-option argument after a bash/sh/python interpreter;
# equal to a glob or ending in /<glob>), AND its environ carries this run's TEAM_RUN_ID or TEAM_DIR.
# Gate for every signal sent to a pid read from a pidfile: after a reboot or pid wraparound that
# number can be sshd or the SSM agent, which `kill -0` cannot tell apart. Only the program position
# counts, so `tail -f bin/x.sh` in the same run does not pass. Unreadable /proc means NOT ours. A
# self-reload re-exec keeps pid, argv and environ, so a reloaded daemon still passes.
proc_pid_is_run_daemon() {
  local pid="${1:-}" a e g prog="" i=0
  shift || true
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$#" -gt 0 ] || return 1
  [ -n "${TEAM_RUN_ID:-}" ] || [ -n "${TEAM_DIR:-}" ] || return 1
  [ -r "/proc/$pid/cmdline" ] && [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' a; do
    if [ "$i" = 0 ]; then
      case "${a##*/}" in bash|sh|dash|python|python3|python3.[0-9]*) i=1; continue ;; esac
      prog="$a"; break
    fi
    case "$a" in -*) continue ;; esac
    prog="$a"; break
  done < <( { cat "/proc/$pid/cmdline"; } 2>/dev/null )
  [ -n "$prog" ] || return 1
  local hit=1
  for g in "$@"; do
    # shellcheck disable=SC2254
    case "$prog" in $g|*/$g) hit=0; break ;; esac
  done
  [ "$hit" = 0 ] || return 1
  while IFS= read -r -d '' e; do
    [ -n "${TEAM_RUN_ID:-}" ] && [ "$e" = "TEAM_RUN_ID=$TEAM_RUN_ID" ] && return 0
    [ -n "${TEAM_DIR:-}" ] && [ "$e" = "TEAM_DIR=$TEAM_DIR" ] && return 0
  done < <( { cat "/proc/$pid/environ"; } 2>/dev/null )
  return 1
}

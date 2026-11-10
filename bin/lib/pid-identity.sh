#!/usr/bin/env bash
# pid-identity.sh -- sourced; decides whether a pid read from a pidfile is safe to signal.

# _proc_prog <pid>: the program <pid> runs, read from its cmdline: argv[0], or, when argv[0] is a
# bash/sh/dash, python or node interpreter, the first non-option argument after it. Sets _PP_PROG
# (empty if none or /proc is unreadable) and _PP_KIND (sh, py or node; empty for a direct program).
# An interpreter option that takes a SEPARATE operand (bash/sh -o/+o/-O/+O, python -W/-X, node
# -r/--require/--import/--loader) skips that operand too: `bash -o pipefail bin/x.sh` used to put
# `pipefail` in program position.
_proc_prog() {
  local a i=0 skip=0
  _PP_PROG=""; _PP_KIND=""
  while IFS= read -r -d '' a; do
    if [ "$i" = 0 ]; then
      case "${a##*/}" in
        bash|sh|dash) i=sh; continue ;;
        python|python3|python3.[0-9]*) i=py; continue ;;
        node|nodejs) i=node; continue ;;
      esac
      _PP_PROG="$a"; break
    fi
    [ "$skip" = 1 ] && { skip=0; continue; }
    # Also a combined short-option cluster that ENDS in the operand-taking letter (`bash -eo pipefail`,
    # `python3 -uW ignore`) and bash's long --rcfile/--init-file.
    case "$i:$a" in
      sh:-*[oO]|sh:+*[oO]|sh:--rcfile|sh:--init-file|py:-*[WX]) skip=1; continue ;;
      node:-r|node:--require|node:--import|node:--loader|node:--experimental-loader) skip=1; continue ;;
    esac
    case "$a" in -*|+*) continue ;; esac
    _PP_PROG="$a"; break
  done < <( { cat "/proc/$1/cmdline"; } 2>/dev/null )
  if [ "$i" != 0 ]; then _PP_KIND="$i"; fi
  return 0
}

# proc_pid_is_run_daemon <pid> <script-glob>... -> 0 only if <pid> is live, the program it runs IS
# one of the scripts (_proc_prog: argv[0], or the first non-option argument after a bash/sh/python/node
# interpreter; equal to a glob or ending in /<glob>), AND its environ carries this run's TEAM_RUN_ID
# or TEAM_DIR.
# Gate for every signal sent to a pid read from a pidfile: after a reboot or pid wraparound that
# number can be sshd or the SSM agent, which `kill -0` cannot tell apart. Only the program position
# counts, so `tail -f bin/x.sh` in the same run does not pass. Unreadable /proc means NOT ours. A
# self-reload re-exec keeps pid, argv and environ, so a reloaded daemon still passes.
proc_pid_is_run_daemon() {
  local pid="${1:-}" e g prog=""
  shift || true
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$#" -gt 0 ] || return 1
  [ -n "${TEAM_RUN_ID:-}" ] || [ -n "${TEAM_DIR:-}" ] || return 1
  [ -r "/proc/$pid/cmdline" ] && [ -r "/proc/$pid/environ" ] || return 1
  _proc_prog "$pid"; prog="$_PP_PROG"
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

# proc_run_daemon_globs <daemon-name> -> the script globs proc_pid_is_run_daemon needs for one of
# this run's pidfile daemons, one per line. Every daemon is bin/<name>.sh except the intake poller,
# which is project-configured: resolved like team-spawn start_intake_poller does ($INTAKE_POLLER, else
# INTAKE_POLLER or WORKDIR/scripts/poller.py from $TEAM_REPO/project.conf, read in a subshell), plus
# the default scripts/poller.py. stop-team/cleanup do not load project.conf themselves, so without
# this a poller at a project path would be refused and left running.
proc_run_daemon_globs() {
  case "${1:-}" in
    intake-poller)
      local p="${INTAKE_POLLER:-}"
      if [ -z "$p" ] && [ -n "${TEAM_REPO:-}" ] && [ -f "$TEAM_REPO/project.conf" ]; then
        # shellcheck disable=SC1091
        p="$( INTAKE_POLLER=""; WORKDIR=""; . "$TEAM_REPO/project.conf" >/dev/null 2>&1
              printf '%s' "${INTAKE_POLLER:-${WORKDIR:+$WORKDIR/scripts/poller.py}}" )"
      fi
      [ -n "$p" ] && printf '%s\n' "$p"
      printf '%s\n' "scripts/poller.py" ;;
    '') return 1 ;;
    *) printf 'bin/%s.sh\n' "$1" ;;
  esac
}

# proc_pidfile_verdict <pidfile> <script-glob>... -> 0 only if the pid in <pidfile> is this run's
# daemon (proc_pid_is_run_daemon). Sets PM_PID to the pid read and, on a refusal, PM_WHY to why, so
# the caller can log ONE line naming pid, file and reason. Only the first
# line counts; it must be all digits. `kill -0` is not a check: after a reboot or pid wrap the number
# can be sshd or the SSM agent.
proc_pidfile_verdict() {
  local f="${1:-}"; shift || true
  PM_PID=""; PM_WHY=""
  # The FIRST whitespace-separated field of the first line: stripping every blank read a
  # pidfile "1 2" as pid 12. Left over CR (a CRLF file) is still dropped.
  local _pm_rest=""
  { read -r PM_PID _pm_rest < "$f"; } 2>/dev/null || [ -n "$PM_PID" ] || { PM_WHY="unreadable or empty pidfile"; return 1; }
  PM_PID="${PM_PID//[[:space:]]/}"
  case "$PM_PID" in
    '') PM_WHY="empty pidfile"; return 1 ;;
    *[!0-9]*) PM_PID="?"; PM_WHY="not a pid"; return 1 ;;
  esac
  [ -d "/proc/$PM_PID" ] || { PM_WHY="not running"; return 1; }
  proc_pid_is_run_daemon "$PM_PID" "$@" && return 0
  PM_WHY="alive but not this run's $* (pid reused, or another run's)"
  return 1
}

# proc_pid_has_run_env <pid> -> 0 if <pid> is alive and its environ carries this run's TEAM_RUN_ID or
# TEAM_DIR. For the DESCENDANTS of a verified root before a delayed SIGKILL: they inherit the run's
# environment, and a pid recycled in the gap does not carry it.
proc_pid_has_run_env() {
  local pid="${1:-}" e
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${TEAM_RUN_ID:-}" ] || [ -n "${TEAM_DIR:-}" ] || return 1
  [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' e; do
    [ -n "${TEAM_RUN_ID:-}" ] && [ "$e" = "TEAM_RUN_ID=$TEAM_RUN_ID" ] && return 0
    [ -n "${TEAM_DIR:-}" ] && [ "$e" = "TEAM_DIR=$TEAM_DIR" ] && return 0
  done < <( { cat "/proc/$pid/environ"; } 2>/dev/null )
  return 1
}

# proc_descendants <pid>: every descendant of <pid>, one per line, children before their own
# children. A teardown captures the tree BEFORE it signals the root: a root without a TERM trap
# dies at once, its children are re-parented, and a `pkill -P <root>` after the TERM finds
# nothing, so a subtree (a model call in a command substitution) ran on. Signal a captured pid
# only after proc_pid_has_run_env: it may have exited and its number been reused since.
proc_descendants() { local c; for c in $(pgrep -P "${1:-}" 2>/dev/null); do echo "$c"; proc_descendants "$c"; done; }

# proc_pid_is_claude_shape <pid> -> 0 if <pid> runs Claude Code, judged by what it executes, never
# by a word somewhere in its args (a script started from a clone named claude-orchestrator is not a
# claude): its name (comm) is `claude`; its executable's basename is `claude`, or the executable sits
# in a native install's claude/versions/ directory (exec'd by its real path, comm and argv[0] carry
# only the version); or its program (_proc_prog) has basename `claude` or sits under
# claude/versions/, or, under node, lies in the @anthropic-ai/claude-code package (an npm install).
# No run check: bin/lib/team-dir-guard.sh judges other runs' directories with it. A role's identity
# is proc_pid_is_run_claude.
proc_pid_is_claude_shape() {
  local pid="${1:-}" comm="" exe=""
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$pid" ] || return 1
  { read -r comm < "/proc/$pid/comm"; } 2>/dev/null || comm=""
  [ "$comm" = claude ] && return 0
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || exe=""
  case "$exe" in */claude|*/claude/versions/*) return 0 ;; esac
  _proc_prog "$pid"
  case "$_PP_PROG" in claude|*/claude|*/claude/versions/*) return 0 ;; esac
  if [ "$_PP_KIND" = node ]; then
    case "$_PP_PROG" in */@anthropic-ai/claude-code/*) return 0 ;; esac
  fi
  return 1
}

# proc_pid_is_run_claude <pid> -> 0 only if <pid> is live, a claude by proc_pid_is_claude_shape, AND
# its environ carries this run's TEAM_RUN_ID or TEAM_DIR (proc_pid_has_run_env, the environ test of
# proc_pid_is_run_daemon). The identity of a role pid read from active, for the liveness checks
# (roster cap, double-spawn guard, reap) and the kill sites alike. `proc_pid_is_run_daemon <pid>
# claude` saw only a program named claude and missed an npm install (`node .../cli.js`) and a
# CLAUDE_BIN under claude/versions/, so every live role of such an install read as dead. A zombie
# fails: its environ is empty.
proc_pid_is_run_claude() {
  proc_pid_is_claude_shape "${1:-}" && proc_pid_has_run_env "${1:-}"
}
# proc_pid_is_run_bus_server <pid> <port> -> 0 only if <pid> is this run's /is bus server.py (the
# proc_pid_is_run_daemon gate: server.py in program position, this run's env -- the first role client
# starts it, so it inherits TEAM_RUN_ID) AND it serves <port>, given as `--port N` or `--port=N`
# (the equals form used to be refused). One gate for stop-team.sh and panic.sh.
proc_pid_is_run_bus_server() {
  local pid="${1:-}" port="${2:-}" a want=0 got=""
  [ -n "$port" ] || return 1
  proc_pid_is_run_daemon "$pid" server.py || return 1
  while IFS= read -r -d '' a; do
    if [ "$want" = 1 ]; then got="$a"; want=0; continue; fi
    case "$a" in --port) want=1 ;; --port=*) got="${a#--port=}" ;; esac
  done < <( { cat "/proc/$pid/cmdline"; } 2>/dev/null )
  [ "$got" = "$port" ]
}

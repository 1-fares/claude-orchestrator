#!/usr/bin/env bash
# stop-team.sh: deterministically tear down a team launched by launch-team.sh.
#
# Order: (1) optional graceful pass, ask each role to stop and save via the pane;
# (2) SIGTERM each recorded process group; (3) SIGKILL survivors and close their
# windows; (4) kill this team's /is bus server; (5) verify. The orchestrator
# window is left alone (use bin/panic.sh to kill everything including it).
#
# claude ignores SIGHUP and survives pty teardown, so we signal the process
# GROUP by the recorded pane pid (reaps claude + its MCP children), and we verify
# a pid is still a claude process before killing it, so a stale .team/active
# never group-kills a recycled, unrelated pid.
#
# Usage: bin/stop-team.sh [--no-graceful]

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# team-env.sh returns 1 when it refuses a pre-set TEAM_DIR (another run's, or a stray export);
# nothing below may run on that unvalidated state.
. "$repo/bin/team-env.sh" || exit 1
# shellcheck source=bin/lib/pid-identity.sh
. "$repo/bin/lib/pid-identity.sh" || exit 1
# shellcheck source=bin/lib/roster.sh
. "$repo/bin/lib/roster.sh" || exit 1   # wid_in_session (shared with retire-role.sh)
session="$TEAM_SESSION"
active="$TEAM_DIR/active"
graceful=1
[ "${1:-}" = "--no-graceful" ] && graceful=0
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

# A recorded role pid is signalled only if it is a claude process of THIS run (a claude by what it
# executes, this run's TEAM_RUN_ID/TEAM_DIR in its environ). The old test, any process whose args
# contain "claude", passed `tail -f ~/.claude/...` or another run's role after a pid wrap, and the
# kill below is a PROCESS-GROUP kill. is_claude comes from bin/lib/roster.sh:
# proc_pid_is_run_claude "$1" (a claude by what it executes, with this run's environ).
# A window id read from active is used (graceful pass, kill-window) only if wid_in_session
# (bin/lib/roster.sh) finds it in THIS run's session: ids are per tmux server, the team
# socket is shared by every run, and after a server restart a stale id names another
# run's window.
role_is_zombie() { /usr/bin/grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null; }
# A role whose claude already exited (on pass 1's TERM, or before this run of stop-team) can leave
# members in its process group that ignored TERM: a tool child, a stuck shell. Pass 2 used to skip
# the whole group once the leader was gone, so they ran on after teardown.
# A process-group id is not reused while any member is alive, so members with pgid == the recorded
# pid ARE that role's group -- unless the number was reused after the group emptied, by a process
# that then exited leaving its own members. So the group is SIGKILLed only if EVERY live member
# (zombies are dead and skipped) carries this run's TEAM_RUN_ID or TEAM_DIR; otherwise it is left
# and one line says so.
kill_exited_role_group() {   # <pgid> <role>
  local g="$1" role="$2" m st members="" foreign="" mine
  # Never the caller's own group: stop-team run from inside a dead role's group would SIGKILL itself
  # (measured: it was spared only because its own short-lived ps/awk members had
  # exited before their environ was read and so counted as foreign -- a race, not a check).
  # ...nor the group of any ANCESTOR: a caller inside the dead role's group that setsid's stop-team
  # gives stop-team a new group, but killing the old one takes the caller.
  local a="$$" ag mine=""
  while [ -n "$a" ] && [ "$a" -gt 1 ] 2>/dev/null; do
    ag="$(ps -o pgid= -p "$a" 2>/dev/null | tr -d ' ')"
    [ -n "$ag" ] && mine="$mine $ag"
    a="$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ')"
  done
  case " $mine " in *" $g "*)
    echo "skip group of exited $role (pgid $g): it is the process group of this stop-team or one of its ancestors; group left"
    return 0 ;;
  esac
  while read -r m st; do
    case "$st" in Z*) continue ;; esac
    [ -d "/proc/$m" ] || continue      # exited since the listing: not a member any more
    members="$members $m"
    proc_pid_has_run_env "$m" || foreign="$foreign $m"
  done < <(ps -eo pid=,pgid=,stat= 2>/dev/null | awk -v g="$g" '$2==g {print $1, $3}')
  [ -n "$members" ] || return 0
  if [ -n "$foreign" ]; then
    echo "skip group of exited $role (pgid $g): member(s)$foreign not this run's; group left"
    return 0
  fi
  kill -KILL "-$g" 2>/dev/null || true
  echo "KILL group of exited $role (pgid $g, members$members)"
}

killed=0

if [ -f "$active" ]; then
  if [ "$graceful" -eq 1 ]; then
    # Ask roles to stop and save via their pane, then give them a moment.
    while IFS=$'\t' read -r pid wid role; do
      [ -n "${wid:-}" ] || continue
      [ "${role:-}" = orchestrator ] && continue   # never send the stop prompt to the orchestrator
      wid_in_session "$wid" || continue            # never type into another run's window
      tmux_submit "$wid" "stop: teardown, finish the current write and stop." || true
    done < "$active"
    sleep 4
  fi

  # Pass 1: SIGTERM each recorded process group (only if still claude).
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    [ "${role:-}" = orchestrator ] && continue   # M1 records the orchestrator in active; never signal/kill it here (panic.sh is the kill-all)
    if is_claude "$pid"; then
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      echo "TERM $role (pid $pid)"; killed=1
    elif [ -d "/proc/$pid" ]; then
      echo "skip $role: pid $pid from $active is alive but not this run's claude; not signalled"
    fi
  done < "$active"

  sleep 2

  # Pass 2: SIGKILL survivors, then close windows.
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    [ "${role:-}" = orchestrator ] && continue   # M1 records the orchestrator in active; never signal/kill it here (panic.sh is the kill-all)
    if is_claude "$pid"; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      echo "KILL $role (pid $pid)"
    elif [ ! -d "/proc/$pid" ] || role_is_zombie "$pid"; then
      kill_exited_role_group "$pid" "$role"
    fi
    wid_in_session "$wid" && tmux kill-window -t "$wid" 2>/dev/null || true
  done < "$active"
fi

# Pidfile daemons. Each pid is signalled only if proc_pid_is_run_daemon says it is THIS run's
# daemon (its script in program position, this run's TEAM_RUN_ID/TEAM_DIR in environ), the gate
# panic.sh and team-spawn already use. `kill -0` alone signalled whatever process now holds the
# number after a reboot or pid wrap. A refused pid gets one line naming
# pid, file and why; the pidfile is ours (it lives in $TEAM_DIR) and stale either way, so it goes.
# Order matters: the tmux watchdog FIRST. While the session and active are up (they are, when the
# orchestrator window stays) it self-heals the api-watchdog, compaction-watchdog, observer, intake
# poller and permission-mode-watchdog, so stopping it after one of them can bring that one back.
# Every daemon also gets pkill -P, as in panic.sh and cleanup.sh: a sleep child holds the per-TEAM_DIR
# flock fd, and the api/compaction watchdogs defer their TERM trap until their foreground sleep
# returns, so TERM alone leaves the lock held for up to one INTERVAL and blocks a relaunch (the
# resource watchdogs were missing until 2026-07-20, permission-mode-watchdog until 2026-11-10).
# observer and intake-poller leaked past stop-team before 2026-06-01.
# The whole descendant tree is captured BEFORE the TERM: a daemon without a TERM trap (the
# observer) dies at once, its children are re-parented, and pkill -P then finds nothing, so
# a model call in progress (command-substitution subshell -> timeout -> claude -p) ran on.
# Captured descendants are signalled only while they carry this run's environment. Then,
# as in panic.sh and cleanup.sh, a re-check and SIGKILL for a daemon that survived TERM.
stop_pidfile_daemon() {   # <name>
  local name="$1" pidf="$TEAM_DIR/$1.pid" globs=() kids k
  [ -f "$pidf" ] || return 0
  mapfile -t globs < <(proc_run_daemon_globs "$name")
  if proc_pidfile_verdict "$pidf" "${globs[@]}"; then
    kids="$(proc_descendants "$PM_PID")"
    kill -TERM "$PM_PID" 2>/dev/null || true
    pkill -TERM -P "$PM_PID" 2>/dev/null || true
    for k in $kids; do proc_pid_has_run_env "$k" && kill -TERM "$k" 2>/dev/null; done
    sleep 0.3
    # Re-verify before escalating: a daemon that exited on TERM leaves a number that can be reused.
    if proc_pid_is_run_daemon "$PM_PID" "${globs[@]}"; then
      pkill -KILL -P "$PM_PID" 2>/dev/null || true
      kill -KILL "$PM_PID" 2>/dev/null || true
    fi
    for k in $kids; do proc_pid_has_run_env "$k" && kill -KILL "$k" 2>/dev/null; done
    echo "stopped $name (pid $PM_PID)"; killed=1
  elif [ "$PM_WHY" != "not running" ]; then
    echo "skip $name: pid $PM_PID from $pidf $PM_WHY; not signalled, pidfile removed"
  fi
  rm -f "$pidf"
}
for _d in tmux-watchdog api-watchdog compaction-watchdog permission-mode-watchdog \
          host-ram-watchdog disk-tmp-watchdog chrome-supervisor observer intake-poller; do
  stop_pidfile_daemon "$_d"
done

# Kill this team's /is bus server (scoped to TEAM_PORT), if we own it.
srv_pidf="$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid"
if [ -f "$srv_pidf" ]; then
  srv_pid="$(cat "$srv_pidf" 2>/dev/null || true)"
  # Same gate: server.py in program position, started under this run (the first role client
  # starts it, so it inherits TEAM_RUN_ID), AND serving this run's port. The pidfile is shared bus
  # state, not ours, so a refused pid leaves it in place.
  if proc_pid_is_run_bus_server "$srv_pid" "$TEAM_PORT"; then
    kill -TERM "$srv_pid" 2>/dev/null || true
    echo "stopped /is bus server (pid $srv_pid, port $TEAM_PORT)"; killed=1
  elif [ -n "$srv_pid" ] && [ -d "/proc/$srv_pid" ]; then
    echo "skip /is bus server: pid $srv_pid from $srv_pidf is alive but not this run's server.py on port $TEAM_PORT; not signalled, pidfile left"
  fi
fi

# Drop the tmux session only if the orchestrator is not living in it.
if tmux has-session -t "$session" 2>/dev/null; then
  if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qx orchestrator; then
    echo "left tmux session '$session' running (orchestrator window present)"
  else
    tmux kill-session -t "$session" 2>/dev/null && echo "killed tmux session '$session'"
  fi
fi

# Verify and clear the record.
if [ -f "$active" ]; then
  survivors=0
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    [ "${role:-}" = orchestrator ] && continue   # M1 records the orchestrator in active; never signal/kill it here (panic.sh is the kill-all)
    if is_claude "$pid"; then
      echo "WARNING: $role (pid $pid) still alive" >&2; survivors=$((survivors+1))
    fi
  done < "$active"
  if [ "$survivors" -eq 0 ]; then
    # Rewrite active, do not delete it: every line whose pid is still this run's claude is
    # kept, or teardown tools and the next launch-team stop seeing it. That is
    # the orchestrator this script leaves running, and a role that add-role.sh or
    # launch-team.sh appended while this script waited for the roster lock: it was not
    # in active when the passes above read it, so it was not stopped and is alive. The
    # roles stopped above no longer pass the check. Under the roster lock, as add-role.sh
    # and retire-role.sh, so an append made at the same moment is not lost.
    {
      if command -v flock >/dev/null 2>&1; then flock -w 30 9 || echo "note: roster lock busy for 30s; rewriting active anyway" >&2; fi
      if keep="$(mktemp "$active.XXXXXX")"; then
        while IFS=$'\t' read -r pid wid role || [ -n "${pid:-}" ]; do
          [ -n "${pid:-}" ] && is_claude "$pid" && printf '%s\t%s\t%s\n' "$pid" "$wid" "$role"
        done < "$active" > "$keep"
        mv -f "$keep" "$active"
      fi
    } 9>"$TEAM_DIR/.roster.lock"
    echo "all roles stopped"
  fi
fi

[ "$killed" -eq 1 ] || echo "no running team found"

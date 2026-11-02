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
. "$repo/bin/team-env.sh"
# shellcheck source=bin/lib/pid-identity.sh
. "$repo/bin/lib/pid-identity.sh" || exit 1
session="$TEAM_SESSION"
active="$TEAM_DIR/active"
graceful=1
[ "${1:-}" = "--no-graceful" ] && graceful=0
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

# A recorded role pid is signalled only if it is a claude process of THIS run (program position
# claude, this run's TEAM_RUN_ID/TEAM_DIR in its environ). The old test, any process whose args
# contain "claude", passed `tail -f ~/.claude/...` or another run's role after a pid wrap, and the
# kill below is a PROCESS-GROUP kill.
is_claude() { proc_pid_is_run_daemon "$1" claude; }

killed=0

if [ -f "$active" ]; then
  if [ "$graceful" -eq 1 ]; then
    # Ask roles to stop and save via their pane, then give them a moment.
    while IFS=$'\t' read -r pid wid role; do
      [ -n "${wid:-}" ] || continue
      [ "${role:-}" = orchestrator ] && continue   # never send the stop prompt to the orchestrator
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
    fi
    [ -n "${wid:-}" ] && tmux kill-window -t "$wid" 2>/dev/null || true
  done < "$active"
fi

# Pidfile daemons. Each pid is signalled only if proc_pid_is_run_daemon says it is THIS run's
# daemon (its script in program position, this run's TEAM_RUN_ID/TEAM_DIR in environ), the gate
# panic.sh and team-spawn already use. `kill -0` alone signalled whatever process now holds the
# number after a reboot or pid wrap. A refused pid gets one line naming
# pid, file and why; the pidfile is ours (it lives in $TEAM_DIR) and stale either way, so it goes.
# Order matters: the tmux watchdog BEFORE the compaction watchdog, so it is not self-healed back up
# between the two kills. The resource watchdogs (host-ram, disk-tmp) also get
# pkill -P: their backgrounded sleep child holds the per-TEAM_DIR flock fd and would otherwise block
# a relaunch for one INTERVAL (missing from this list until 2026-07-20). observer and intake-poller
# leaked past stop-team before 2026-06-01.
stop_pidfile_daemon() {   # <name> [children]
  local name="$1" kids="${2:-}" pidf="$TEAM_DIR/$1.pid" globs=()
  [ -f "$pidf" ] || return 0
  mapfile -t globs < <(proc_run_daemon_globs "$name")
  if proc_pidfile_verdict "$pidf" "${globs[@]}"; then
    kill -TERM "$PM_PID" 2>/dev/null || true
    [ "$kids" = children ] && { pkill -TERM -P "$PM_PID" 2>/dev/null || true; }
    echo "stopped $name (pid $PM_PID)"; killed=1
  elif [ "$PM_WHY" != "not running" ]; then
    echo "skip $name: pid $PM_PID from $pidf $PM_WHY; not signalled, pidfile removed"
  fi
  rm -f "$pidf"
}
stop_pidfile_daemon api-watchdog
stop_pidfile_daemon tmux-watchdog
stop_pidfile_daemon compaction-watchdog
for _rw in host-ram-watchdog disk-tmp-watchdog; do
  stop_pidfile_daemon "$_rw" children
done
stop_pidfile_daemon chrome-supervisor
stop_pidfile_daemon observer
stop_pidfile_daemon intake-poller

# Kill this team's /is bus server (scoped to TEAM_PORT), if we own it.
srv_pidf="$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid"
if [ -f "$srv_pidf" ]; then
  srv_pid="$(cat "$srv_pidf" 2>/dev/null || true)"
  # Same gate: server.py in program position, started under this run (the first role client
  # starts it, so it inherits TEAM_RUN_ID), AND serving this run's port. The pidfile is shared bus
  # state, not ours, so a refused pid leaves it in place.
  if proc_pid_is_run_daemon "$srv_pid" server.py && \
     [ "$(tr '\0' '\n' < "/proc/$srv_pid/cmdline" 2>/dev/null | sed -n '/^--port$/{n;p;q}')" = "$TEAM_PORT" ]; then
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
  [ "$survivors" -eq 0 ] && rm -f "$active" && echo "all roles stopped"
fi

[ "$killed" -eq 1 ] || echo "no running team found"

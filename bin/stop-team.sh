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
session="$TEAM_SESSION"
active="$TEAM_DIR/active"
graceful=1
[ "${1:-}" = "--no-graceful" ] && graceful=0
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

is_claude() { ps -p "$1" -o args= 2>/dev/null | grep -q '[c]laude'; }

killed=0

if [ -f "$active" ]; then
  if [ "$graceful" -eq 1 ]; then
    # Ask roles to stop and save via their pane, then give them a moment.
    while IFS=$'\t' read -r pid wid role; do
      [ -n "${wid:-}" ] || continue
      tmux send-keys -t "$wid" -l "stop: teardown, finish the current write and stop." 2>/dev/null && \
        tmux send-keys -t "$wid" Enter 2>/dev/null || true
    done < "$active"
    sleep 4
  fi

  # Pass 1: SIGTERM each recorded process group (only if still claude).
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && is_claude "$pid"; then
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      echo "TERM $role (pid $pid)"; killed=1
    fi
  done < "$active"

  sleep 2

  # Pass 2: SIGKILL survivors, then close windows.
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && is_claude "$pid"; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      echo "KILL $role (pid $pid)"
    fi
    [ -n "${wid:-}" ] && tmux kill-window -t "$wid" 2>/dev/null || true
  done < "$active"
fi

# Kill the API watchdog, if launch-team.sh started one for this run.
wd_pidf="$TEAM_DIR/api-watchdog.pid"
if [ -f "$wd_pidf" ]; then
  wd_pid="$(cat "$wd_pidf" 2>/dev/null || true)"
  if [ -n "$wd_pid" ] && kill -0 "$wd_pid" 2>/dev/null; then
    kill -TERM "$wd_pid" 2>/dev/null || true
    echo "stopped api-watchdog (pid $wd_pid)"; killed=1
  fi
  rm -f "$wd_pidf"
fi

# Kill the tmux watchdog (May-2026 addition).
tw_pidf="$TEAM_DIR/tmux-watchdog.pid"
if [ -f "$tw_pidf" ]; then
  tw_pid="$(cat "$tw_pidf" 2>/dev/null || true)"
  if [ -n "$tw_pid" ] && kill -0 "$tw_pid" 2>/dev/null; then
    kill -TERM "$tw_pid" 2>/dev/null || true
    echo "stopped tmux-watchdog (pid $tw_pid)"; killed=1
  fi
  rm -f "$tw_pidf"
fi

# Kill the dashboard server, if launch-team.sh started one for this run. The
# server's serve_forever loop does not unwind on plain SIGTERM, so we escalate
# to SIGKILL after a short grace window rather than leave a stray listener bound
# on a loopback port.
db_pidf="$TEAM_DIR/dashboard.pid"
if [ -f "$db_pidf" ]; then
  db_pid="$(cat "$db_pidf" 2>/dev/null || true)"
  if [ -n "$db_pid" ] && kill -0 "$db_pid" 2>/dev/null \
     && ps -p "$db_pid" -o args= 2>/dev/null | grep -q '[d]ashboard/server/server.py'; then
    kill -TERM "$db_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$db_pid" 2>/dev/null || break; sleep 0.3; done
    kill -0 "$db_pid" 2>/dev/null && kill -KILL "$db_pid" 2>/dev/null || true
    echo "stopped dashboard (pid $db_pid)"; killed=1
  fi
  rm -f "$db_pidf" "$TEAM_DIR/dashboard.url"
fi

# Kill this team's /is bus server (scoped to TEAM_PORT), if we own it.
srv_pidf="$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid"
if [ -f "$srv_pidf" ]; then
  srv_pid="$(cat "$srv_pidf" 2>/dev/null || true)"
  if [ -n "$srv_pid" ] && kill -0 "$srv_pid" 2>/dev/null && \
     ps -p "$srv_pid" -o args= 2>/dev/null | grep -q '[s]erver.py'; then
    kill -TERM "$srv_pid" 2>/dev/null || true
    echo "stopped /is bus server (pid $srv_pid, port $TEAM_PORT)"; killed=1
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
    if kill -0 "$pid" 2>/dev/null && is_claude "$pid"; then
      echo "WARNING: $role (pid $pid) still alive" >&2; survivors=$((survivors+1))
    fi
  done < "$active"
  [ "$survivors" -eq 0 ] && rm -f "$active" && echo "all roles stopped"
fi

[ "$killed" -eq 1 ] || echo "no running team found"

#!/usr/bin/env bash
# panic.sh: the blind "stop everything now" button. Unlike stop-team.sh, this
# also kills the orchestrator and the whole team tmux session. Use it when a run
# is misbehaving (runaway loop, ping-pong, wrong direction) and you just want it
# all to stop.
#
# It kills the process group of every pane in the team session (claude survives
# SIGHUP, so killing the session alone is not enough), then any pids recorded in
# .team/active that are not in the session, then this team's /is bus server.
#
# Usage: bin/panic.sh

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

killed=0

if tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  pids="$(tmux list-panes -s -t "$TEAM_SESSION" -F '#{pane_pid}' 2>/dev/null)"
  for pp in $pids; do kill -TERM "-$pp" 2>/dev/null || kill -TERM "$pp" 2>/dev/null || true; done
  sleep 2
  for pp in $pids; do kill -KILL "-$pp" 2>/dev/null || kill -KILL "$pp" 2>/dev/null || true; done
  tmux kill-session -t "$TEAM_SESSION" 2>/dev/null || true
  echo "panic: killed tmux session '$TEAM_SESSION' and its panes"
  killed=1
fi

# Any recorded pids not in the session (e.g. detached launch).
if [ -f "$repo/.team/active" ]; then
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      echo "panic: killed $role (pid $pid)"; killed=1
    fi
  done < "$repo/.team/active"
  rm -f "$repo/.team/active"
fi

srv_pidf="$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid"
if [ -f "$srv_pidf" ]; then
  srv_pid="$(cat "$srv_pidf" 2>/dev/null || true)"
  if [ -n "$srv_pid" ] && kill -0 "$srv_pid" 2>/dev/null && \
     ps -p "$srv_pid" -o args= 2>/dev/null | grep -q '[s]erver.py'; then
    kill -TERM "$srv_pid" 2>/dev/null || true
    echo "panic: stopped /is bus server (pid $srv_pid, port $TEAM_PORT)"; killed=1
  fi
fi

[ "$killed" -eq 1 ] && echo "panic: done" || echo "panic: nothing was running"

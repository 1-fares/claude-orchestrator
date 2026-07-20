#!/usr/bin/env bash
# panic.sh: the blind "stop everything now" button. Unlike stop-team.sh, this
# also kills the orchestrator and the whole team tmux session. Use it when a run
# is misbehaving (runaway loop, ping-pong, wrong direction) and you just want it
# all to stop.
#
# It captures each pane's process tree (claude plus its children), kills it,
# kills the tmux session, kills any recorded pids and this team's /is bus server,
# then VERIFIES the session is actually gone and reports the truth (claude
# ignores gentler signals, so we SIGKILL and check).
#
# Run it in the same environment the team runs in (your terminal). Usage: bin/panic.sh

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

# Collect a pid and all its descendants.
descendants() { local p c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

killed=0
tree=""
if tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  for pp in $(tmux list-panes -s -t "$TEAM_SESSION" -F '#{pane_pid}' 2>/dev/null); do
    tree="$tree $pp $(descendants "$pp")"
  done
  # signal process groups, then kill the session, then SIGKILL the captured tree
  for p in $tree; do kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; done
  tmux kill-session -t "$TEAM_SESSION" 2>/dev/null || true
  sleep 1
  for p in $tree; do kill -KILL "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; done
  echo "panic: killed tmux session '$TEAM_SESSION' and its process tree"
  killed=1
fi

# Any recorded pids not in the session (e.g. a detached launch).
if [ -f "$TEAM_DIR/active" ]; then
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      echo "panic: killed $role (pid $pid)"; killed=1
    fi
  done < "$TEAM_DIR/active"
  rm -f "$TEAM_DIR/active"
fi

# API watchdog (if launch-team.sh started one).
wd_pidf="$TEAM_DIR/api-watchdog.pid"
if [ -f "$wd_pidf" ]; then
  wd_pid="$(cat "$wd_pidf" 2>/dev/null || true)"
  if [ -n "$wd_pid" ] && kill -0 "$wd_pid" 2>/dev/null; then
    kill -KILL "$wd_pid" 2>/dev/null || true
    echo "panic: killed api-watchdog (pid $wd_pid)"; killed=1
  fi
  rm -f "$wd_pidf"
fi

# All detached nohup daemons: tmux-watchdog, chrome-supervisor, observer, the
# intake poller, AND every resource watchdog (compaction / host-ram / disk-tmp).
# The tmux pane-tree sweep above does NOT reach them, so panic must reap them by
# pidfile or they leak past a panic. History: 2026-06-01 panic killed only the
# api-watchdog + dashboard and orphaned the rest; 2026-07-20 the reap list was
# MISSING the host-ram/disk-tmp resource watchdogs, so their OLD instances
# survived every restart and ran alongside the fresh set -- two compaction-style
# watchdogs doubling /compact + /context keystrokes into panes.
#
# Reap correctness: each watchdog backgrounds a `sleep` that INHERITS the
# per-TEAM_DIR flock fd. A bare `kill` of the parent orphans that sleep
# (reparented to init), which keeps the singleton lock held for up to one
# INTERVAL -- long enough to block the resume's relaunch. So reap the CHILD too:
# `kill -TERM` lets the daemon's own TERM/EXIT trap reap its sleep, and
# `pkill -P` frees the lock at once for the pre-trap (older-code) instances.
_reap_daemon() {
  local name="$1" pidf="$TEAM_DIR/$1.pid" pid
  [ -f "$pidf" ] || return 0
  pid="$(cat "$pidf" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true          # trap-aware exit (new code self-reaps its sleep)
    pkill -TERM -P "$pid" 2>/dev/null || true       # reap the sleep child -> frees the flock fd now
    sleep 0.3
    pkill -KILL -P "$pid" 2>/dev/null || true       # force any survivor sleep
    kill -KILL "$pid" 2>/dev/null || true           # force the parent if it ignored TERM
    echo "panic: killed $name (pid $pid) + reaped its sleep child"; killed=1
  fi
  rm -f "$pidf"
}
for _d in compaction-watchdog host-ram-watchdog disk-tmp-watchdog \
          tmux-watchdog chrome-supervisor observer intake-poller; do
  _reap_daemon "$_d"
done

# Dashboard server (if launch-team.sh started one).
db_pidf="$TEAM_DIR/dashboard.pid"
if [ -f "$db_pidf" ]; then
  db_pid="$(cat "$db_pidf" 2>/dev/null || true)"
  if [ -n "$db_pid" ] && kill -0 "$db_pid" 2>/dev/null \
     && ps -p "$db_pid" -o args= 2>/dev/null | grep -q '[d]ashboard/server/server.py'; then
    kill -KILL "$db_pid" 2>/dev/null || true
    echo "panic: killed dashboard (pid $db_pid)"; killed=1
  fi
  rm -f "$db_pidf" "$TEAM_DIR/dashboard.url"
fi

# This team's /is bus server (scoped to TEAM_PORT).
srv_pidf="$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid"
if [ -f "$srv_pidf" ]; then
  srv_pid="$(cat "$srv_pidf" 2>/dev/null || true)"
  if [ -n "$srv_pid" ] && kill -0 "$srv_pid" 2>/dev/null && \
     ps -p "$srv_pid" -o args= 2>/dev/null | grep -q '[s]erver.py'; then
    kill -TERM "$srv_pid" 2>/dev/null || true
    echo "panic: stopped /is bus server (pid $srv_pid, port $TEAM_PORT)"; killed=1
  fi
fi

# Verify and report the truth.
sleep 1
if tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  echo "panic: WARNING session '$TEAM_SESSION' is STILL up. Last resort (kills only" >&2
  echo "       this server; safe if no other tmux work): tmux kill-server" >&2
  exit 1
fi
survivors=0
for p in $tree; do kill -0 "$p" 2>/dev/null && survivors=$((survivors+1)); done
if [ "$survivors" -gt 0 ]; then
  echo "panic: WARNING $survivors process(es) from the team are still alive" >&2
  exit 1
fi

[ "$killed" -eq 1 ] && echo "panic: done, session gone and processes reaped" || echo "panic: nothing was running"

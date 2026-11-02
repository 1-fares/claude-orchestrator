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
# IDENTITY CHECK, OR A LOUD FALLBACK. Every pid read from a file is
# signalled only if it is THIS run's process (proc_pid_is_run_daemon: the program in program
# position, this run's TEAM_RUN_ID/TEAM_DIR in its environ). This is the emergency stop, so it must
# not do LESS when that check cannot run: it used to `exit 1` here before killing anything if
# pid-identity.sh failed to load (a bad commit to the library disabled the panic button). Now, if the
# library does not load or /proc/<pid>/environ is not readable on this host, it says so on stderr and
# falls back to the older match -- live pid (kill -0) whose args name the program -- for every
# pid-from-a-file below. The tmux pane trees need no identity check and are always killed.
pm_mode=identity; pm_why=""
# shellcheck source=bin/lib/pid-identity.sh
if ! . "$repo/bin/lib/pid-identity.sh" 2>/dev/null || ! declare -F proc_pid_is_run_daemon proc_pid_is_run_bus_server >/dev/null; then
  pm_mode=args; pm_why="bin/lib/pid-identity.sh did not load"
elif [ ! -r "/proc/$$/environ" ]; then
  pm_mode=args; pm_why="/proc/<pid>/environ is not readable on this host"
fi
[ "$pm_mode" = args ] && echo "panic: WARNING identity check unavailable ($pm_why): pids read from files are matched by their args only (the older behaviour)" >&2
# _args_match <pid> <pattern>...: the fallback test. Live pid one of whose `ps args` WORDS has the
# pattern's basename as its own basename. A WORD, not a substring: the older
# substring match took `claude-helper` for claude and `myserver.py` for server.py.
_args_match() {
  local pid="$1" args w g; shift
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
  for w in $args; do
    for g in "$@"; do [ "${w##*/}" = "${g##*/}" ] && return 0; done
  done
  return 1
}
# _is_run <pid> <glob>...: this run's process running one of the globs.
_is_run() {
  if [ "$pm_mode" = identity ]; then proc_pid_is_run_daemon "$@"; else _args_match "$@"; fi
}
# _owns_listen_port <pid> <port>: <pid> holds a LISTENING TCP socket on <port> -- the socket inode
# from /proc/net/tcp{,6} (state 0A) is one of its fds. Library-free on purpose (it runs in the
# fallback too). The bus server gets its socket as an inherited fd (--fd 8), which this sees.
_owns_listen_port() {
  local pid="$1" port="$2" hex i fd
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  hex="$(printf '%04X' "$port")"
  for i in $(awk -v h=":$hex" 'NR>1 && $4=="0A" && substr($2, length($2)-4)==h {print $10}' /proc/net/tcp /proc/net/tcp6 2>/dev/null); do
    for fd in /proc/"$pid"/fd/*; do
      [ "$(readlink "$fd" 2>/dev/null)" = "socket:[$i]" ] && return 0
    done
  done
  return 1
}
# _is_run_bus <pid>: this run's /is bus server on TEAM_PORT. It used to be `kill -0` plus "args
# contain server.py" even with the identity check available, so a reused pid running any server.py
# (another team's bus, an unrelated app) was TERMed. Accepted: this run's server.py on TEAM_PORT by
# identity, OR -- panic only, it is the emergency stop and must not stop LESS than before -- the pid
# named by server.<TEAM_PORT>.pid that is server.py AND provably LISTENS on TEAM_PORT, even without
# the run env (a client that joined without it started the bus) or a --port argument. Only one
# process can listen on a port, so that IS this run's bus. A server on another port stays refused.
_is_run_bus() {
  if [ "$pm_mode" = identity ] && proc_pid_is_run_bus_server "$1" "$TEAM_PORT"; then return 0; fi
  _args_match "$1" server.py || return 1
  _owns_listen_port "$1" "$TEAM_PORT" && return 0
  [ "$pm_mode" = identity ] && return 1
  case " $(ps -p "$1" -o args= 2>/dev/null) " in *" --port $TEAM_PORT "*|*" --port=$TEAM_PORT "*) return 0 ;; esac
  return 1
}
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
    # A GROUP kill: gated on this run's claude, not "args contain claude" (a stale active line
    # after a reboot could name any process, and -pid takes its whole group).
    if _is_run "$pid" claude; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      echo "panic: killed $role (pid $pid)"; killed=1
    elif [ -d "/proc/$pid" ] && [ ! -r "/proc/$pid/environ" ]; then
      echo "panic: skip $role: pid $pid from $TEAM_DIR/active: its environ is not readable (another uid, or hidepid), so it cannot be identified; not signalled"
    elif [ -d "/proc/$pid" ]; then
      echo "panic: skip $role: pid $pid from $TEAM_DIR/active is alive but not this run's claude; not signalled"
    fi
  done < "$TEAM_DIR/active"
  rm -f "$TEAM_DIR/active"
fi

# API watchdog (if launch-team.sh started one).
wd_pidf="$TEAM_DIR/api-watchdog.pid"
if [ -f "$wd_pidf" ]; then
  wd_pid="$(cat "$wd_pidf" 2>/dev/null || true)"
  if [ -n "$wd_pid" ] && _is_run "$wd_pid" "bin/api-watchdog.sh"; then
    kill -KILL "$wd_pid" 2>/dev/null || true
    echo "panic: killed api-watchdog (pid $wd_pid)"; killed=1
  elif [ -n "$wd_pid" ] && [ -d "/proc/$wd_pid" ]; then
    echo "panic: stale api-watchdog pidfile: pid $wd_pid is not this run's api-watchdog; not signalled, pidfile removed"
  fi
  rm -f "$wd_pidf"
fi

# All detached nohup daemons: tmux-watchdog, chrome-supervisor, observer, the
# intake poller, AND every resource watchdog (compaction / host-ram / disk-tmp).
# The tmux pane-tree sweep above does NOT reach them, so panic must reap them by
# pidfile or they leak past a panic. History: 2026-06-01 panic killed only the
# api-watchdog and orphaned the rest; 2026-07-20 the reap list was
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
# Script globs per daemon; the intake poller is project-configured (team-spawn start_intake_poller).
_daemon_globs() {
  # The shared resolver (it also reads project.conf, as stop-team and cleanup do) when it loaded.
  if [ "$pm_mode" = identity ] && declare -F proc_run_daemon_globs >/dev/null; then proc_run_daemon_globs "$1"; return; fi
  case "$1" in
    intake-poller) printf '%s\n' "${INTAKE_POLLER:-scripts/poller.py}" "scripts/poller.py" ;;
    *) printf '%s\n' "bin/$1.sh" ;;
  esac
}
_reap_daemon() {
  local name="$1" pidf="$TEAM_DIR/$1.pid" pid globs=()
  [ -f "$pidf" ] || return 0
  mapfile -t globs < <(_daemon_globs "$name")
  pid="$(cat "$pidf" 2>/dev/null || true)"
  if [ -n "$pid" ] && _is_run "$pid" "${globs[@]}"; then
    kill -TERM "$pid" 2>/dev/null || true          # trap-aware exit (new code self-reaps its sleep)
    pkill -TERM -P "$pid" 2>/dev/null || true       # reap the sleep child -> frees the flock fd now
    sleep 0.3
    # Re-verify before escalating: a daemon that exited on TERM leaves a pid that can be reused.
    if _is_run "$pid" "${globs[@]}"; then
      pkill -KILL -P "$pid" 2>/dev/null || true     # force any survivor sleep
      kill -KILL "$pid" 2>/dev/null || true         # force the parent if it ignored TERM
    fi
    echo "panic: killed $name (pid $pid) + reaped its sleep child"; killed=1
  elif [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    echo "panic: stale $name pidfile: pid $pid is not this run's $name; not signalled, pidfile removed"
  fi
  rm -f "$pidf"
}
for _d in compaction-watchdog host-ram-watchdog disk-tmp-watchdog \
          tmux-watchdog permission-mode-watchdog chrome-supervisor observer intake-poller; do
  _reap_daemon "$_d"
done

# This team's /is bus server (scoped to TEAM_PORT).
srv_pidf="$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid"
if [ -f "$srv_pidf" ]; then
  srv_pid="$(cat "$srv_pidf" 2>/dev/null || true)"
  if [ -n "$srv_pid" ] && _is_run_bus "$srv_pid"; then
    kill -TERM "$srv_pid" 2>/dev/null || true
    echo "panic: stopped /is bus server (pid $srv_pid, port $TEAM_PORT)"; killed=1
  elif [ -n "$srv_pid" ] && [ -d "/proc/$srv_pid" ]; then
    echo "panic: skip /is bus server: pid $srv_pid from $srv_pidf is not this run's server.py on port $TEAM_PORT; not signalled, pidfile left"
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

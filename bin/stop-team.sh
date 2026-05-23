#!/usr/bin/env bash
# stop-team.sh: deterministically tear down a team launched by launch-team.sh.
#
# claude ignores SIGHUP and survives loss of its pty, so killing the tmux window
# is not enough: a role keeps running after the window closes. Teardown therefore
# signals each role's process GROUP by the pane pid the launcher recorded (which
# reaps claude and its MCP child processes), then closes the tmux windows.
#
# This is a script, not an LLM step, because teardown across N sessions must be
# exact and repeatable (see README "Scripts over judgement").
#
# Usage: bin/stop-team.sh

set -uo pipefail   # not -e: kill on an already-dead pid returns non-zero

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
session="orchestrator-team"
active="$repo/.team/active"
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

killed=0

if [ -f "$active" ]; then
  # Pass 1: SIGTERM each recorded process group.
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      echo "TERM $role (pid $pid)"
      killed=1
    fi
  done < "$active"

  sleep 2

  # Pass 2: SIGKILL survivors, then close the windows.
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      echo "KILL $role (pid $pid)"
    fi
    [ -n "${wid:-}" ] && tmux kill-window -t "$wid" 2>/dev/null || true
  done < "$active"

  rm -f "$active"
fi

# Belt and suspenders: drop the detached session if it still exists.
if tmux has-session -t "$session" 2>/dev/null; then
  tmux kill-session -t "$session" 2>/dev/null || true
  echo "killed tmux session '$session'"
  killed=1
fi

[ "$killed" -eq 1 ] || echo "no running team found"

#!/usr/bin/env bash
# cleanup.sh: thorough teardown for misfires and orphans. Stops this clone's team,
# reaps ORPHANED role sessions that survive a lost tmux window (which
# reset.sh/panic.sh can miss when .team/active is gone or the session was killed
# out from under the roles), removes stale state, and optionally purges per-clone
# config back to the committed clone.
#
# Safe by default: with no flags it is a DRY RUN (reports what it would do, kills
# and removes nothing). It only targets THIS clone: its tmux socket/session, the
# pids in its .team/active, and processes whose environment has ORCH_HOME=<this
# repo>. It never kills your other Claude sessions and never kills a running /is
# bus server (those idle-shutdown on their own; only stale pidfiles are removed),
# so your personal /is use is untouched.
#
# Usage:
#   bin/cleanup.sh                  # dry run: report orphans + cruft, change nothing
#   bin/cleanup.sh --force          # stop the team, reap orphans, remove .team/ + stale pidfiles
#   bin/cleanup.sh --force --purge  # also remove project.conf, team.tmux.conf, and
#                                   # untracked files under goals/ tasks/ roles/
#
# For a normal end-of-run reset use bin/reset.sh; reach for cleanup.sh when a run
# misfired and left orphans the normal teardown cannot see.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"   # TEAM_SESSION, TEAM_TMUX, TEAM_PORT, tmux() wrapper

force=0; purge=0; unsigned_too=0
for a in "$@"; do case "$a" in
  --force) force=1 ;;
  --purge) purge=1 ;;
  --include-unsigned) unsigned_too=1 ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a (try --help)" >&2; exit 2 ;;
esac; done
DRY=1; [ "$force" = 1 ] && DRY=0
tag(){ [ "$DRY" = 1 ] && printf '[would] %s\n' "$*" || printf '[done]  %s\n' "$*"; }

descendants(){ local p c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
killtree(){ # $* pids: TERM then KILL the process groups/pids (no-op in dry run)
  [ "$DRY" = 1 ] && return 0
  local p; for p in "$@"; do kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; done
  sleep 1
  for p in "$@"; do kill -KILL "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; done
}

echo "== cleanup: clone=$repo"
echo "== socket=$TEAM_TMUX session=$TEAM_SESSION bus-port=$TEAM_PORT  mode=$([ "$DRY" = 1 ] && echo DRY-RUN || echo APPLY)"

# 1. Team tmux session (+ its pane process trees).
if tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then
  tree=""
  for pp in $(tmux list-panes -s -t "$TEAM_SESSION" -F '#{pane_pid}' 2>/dev/null); do
    tree="$tree $pp $(descendants "$pp")"
  done
  tag "kill tmux session $TEAM_SESSION and its pane trees:$tree"
  if [ "$DRY" = 0 ]; then killtree $tree; tmux kill-session -t "$TEAM_SESSION" 2>/dev/null || true; fi
else
  echo "   no team tmux session on $TEAM_TMUX"
fi

# 2. Pids recorded in .team/active (claude-guarded), if any.
if [ -f "$repo/.team/active" ]; then
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
      tag "reap recorded role '$role' (pid $pid)"; killtree "$pid" $(descendants "$pid")
    fi
  done < "$repo/.team/active"
fi

# 3. Orphaned role sessions: a claude process tree running an /is client with no
#    owning team tmux. "Signed" orphans carry ORCH_HOME=this repo (launched by this
#    clone's launch-team) and are reaped automatically. "Unsigned" ones (no
#    ORCH_HOME, e.g. a manual or misfired launch on the default bus) cannot be told
#    apart from your personal /is sessions, so they are only listed unless you pass
#    --include-unsigned.
mapfile -t _clients < <(pgrep -f 'skills/is/bin/client.py --name' 2>/dev/null || true)
declare -A _seen=(); signed=(); unsigned=()
for cp in "${_clients[@]:-}"; do
  [ -n "${cp:-}" ] || continue
  case "$(ps -o comm= -p "$cp" 2>/dev/null)" in python*) ;; *) continue ;; esac  # real client.py, not a wrapper shell
  a="$cp"; cl=""
  for _ in 1 2 3 4 5 6 7 8; do
    pa=$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' '); [ -n "$pa" ] || break
    [ "$(ps -o comm= -p "$pa" 2>/dev/null)" = "claude" ] && { cl="$pa"; break; }
    a="$pa"
  done
  [ -n "$cl" ] || continue
  [ -n "${_seen[$cl]:-}" ] && continue; _seen[$cl]=1
  # A live pane of THIS team session is not an orphan.
  if tmux has-session -t "$TEAM_SESSION" 2>/dev/null && \
     tmux list-panes -s -t "$TEAM_SESSION" -F '#{pane_pid}' 2>/dev/null | grep -qx "$cl"; then
    continue
  fi
  role=$(ps -o args= -p "$cp" 2>/dev/null | grep -oP '(?<=--name )\S+' | head -1)
  if grep -qxF "ORCH_HOME=$repo" <(tr '\0' '\n' < "/proc/$cl/environ" 2>/dev/null); then
    signed+=("$cl:${role:-?}")
  else
    unsigned+=("$cl:${role:-?}")
  fi
done
if [ "${#signed[@]}" -gt 0 ]; then
  for o in "${signed[@]}"; do cl="${o%%:*}"; role="${o#*:}"
    tag "reap orphaned role '$role' (this clone; claude pid $cl + tree)"
    killtree "$cl" $(descendants "$cl"); done
else
  echo "   no signed orphans (launched by this clone's launch-team)"
fi
if [ "${#unsigned[@]}" -gt 0 ]; then
  echo "   unsigned /is sessions (no ORCH_HOME: a misfired launch OR your personal /is):"
  for o in "${unsigned[@]}"; do cl="${o%%:*}"; role="${o#*:}"
    if [ "$unsigned_too" = 1 ]; then
      tag "reap UNSIGNED /is session '$role' (--include-unsigned; claude pid $cl + tree)"
      killtree "$cl" $(descendants "$cl")
    else
      echo "        pid $cl  role '$role'  (kept; re-run with --include-unsigned to reap)"
    fi
  done
fi

# 4. Stale /is bus pidfiles (dead pids only; never kill a live bus server).
for pf in "$HOME/.claude/data/inter-session/"server.*.pid; do
  [ -e "$pf" ] || continue
  bpid=$(cat "$pf" 2>/dev/null || true)
  if [ -n "$bpid" ] && ! kill -0 "$bpid" 2>/dev/null; then
    tag "remove stale bus pidfile $(basename "$pf") (pid $bpid dead)"
    [ "$DRY" = 0 ] && rm -f "$pf" "${pf}.meta"
  fi
done

# 5. Run state.
if [ -d "$repo/.team" ]; then
  tag "remove .team/ (ledger, prompts, evidence, active)"
  [ "$DRY" = 0 ] && rm -rf "$repo/.team"
fi

# 6. Purge per-clone config and untracked session artifacts (back to committed clone).
if [ "$purge" = 1 ]; then
  for f in project.conf team.tmux.conf; do
    [ -e "$repo/$f" ] && { tag "remove $f"; [ "$DRY" = 0 ] && rm -f "$repo/$f"; }
  done
  unt=$(git -C "$repo" ls-files --others --exclude-standard -- goals/ tasks/ roles/ 2>/dev/null || true)
  if [ -n "$unt" ]; then
    tag "remove untracked artifacts under goals/ tasks/ roles/:"
    printf '%s\n' "$unt" | sed 's/^/        /'
    [ "$DRY" = 0 ] && ( cd "$repo" && printf '%s\n' "$unt" | xargs -r rm -f )
  fi
fi

if [ "$DRY" = 1 ]; then
  echo "== dry run only. Re-run with --force (add --purge for config/artifacts) to apply."
else
  echo "== cleanup applied."
fi

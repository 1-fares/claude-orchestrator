#!/usr/bin/env bash
# cleanup.sh: thorough teardown for misfires and orphans. Stops this clone's team,
# reaps ORPHANED role sessions that survive a lost tmux window (which
# reset.sh/panic.sh can miss when .team/active is gone or the session was killed
# out from under the roles), removes stale state, and optionally purges per-clone
# config back to the committed clone.
#
# SAFETY (hard rules, learned the hard way):
#   - Dry run unless --force.
#   - It ONLY kills processes positively attributable to THIS clone's team: the
#     team tmux session's panes, pids recorded in .team/active, and claude trees
#     whose environment has ORCH_HOME=<this repo>. It will NOT kill any other
#     process, EVER, even if it looks orphaned. Other /is sessions on the shared
#     bus are your own work; they are reported, never touched. (There is
#     deliberately no flag to kill them: a script cannot tell a busy session from
#     a stranded one, and a process running a script is ALIVE, not stuck.)
#   - It never kills a running /is bus server (only removes stale pidfiles whose
#     pid is already dead), so the shared bus and everything on it is safe.
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

force=0; purge=0
for a in "$@"; do case "$a" in
  --force) force=1 ;;
  --purge) purge=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
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
if [ -f "$TEAM_DIR/active" ]; then
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${pid:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
      tag "reap recorded role '$role' (pid $pid)"; killtree "$pid" $(descendants "$pid")
    fi
  done < "$TEAM_DIR/active"
fi

# 3. Orphaned role sessions: a claude process tree running an /is client with no
#    owning team tmux. ONLY "signed" orphans (ORCH_HOME=this repo, i.e. launched by
#    this clone's launch-team) are reaped, because only those are positively ours.
#    "Unsigned" /is sessions (no ORCH_HOME, e.g. your own sessions on the shared
#    default bus) cannot be told apart from live work, so they are REPORTED ONLY
#    and never killed. There is intentionally no override for this.
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
  echo "   NOTE: ${#unsigned[@]} other /is session(s) are running that are NOT this clone's"
  echo "   team (no ORCH_HOME signature). These are almost certainly YOUR OWN work on the"
  echo "   shared /is bus. cleanup NEVER touches them. Listed for awareness only:"
  for o in "${unsigned[@]}"; do cl="${o%%:*}"; role="${o#*:}"
    echo "        pid $cl  role '$role'  (LEFT RUNNING)"
  done
  echo "   To stop one of these, do it yourself after confirming it is not live work."
fi

# 3b. API watchdog (if launch-team.sh started one for this clone's team).
wd_pidf="$TEAM_DIR/api-watchdog.pid"
if [ -f "$wd_pidf" ]; then
  wd_pid="$(cat "$wd_pidf" 2>/dev/null || true)"
  if [ -n "$wd_pid" ] && kill -0 "$wd_pid" 2>/dev/null; then
    tag "kill api-watchdog (pid $wd_pid)"
    [ "$DRY" = 0 ] && { kill -TERM "$wd_pid" 2>/dev/null || true; sleep 1; kill -KILL "$wd_pid" 2>/dev/null || true; rm -f "$wd_pidf"; }
  else
    [ "$DRY" = 0 ] && rm -f "$wd_pidf"
  fi
fi

# 3b'. tmux watchdog (May-2026 addition: detects dead tmux server).
tw_pidf="$TEAM_DIR/tmux-watchdog.pid"
if [ -f "$tw_pidf" ]; then
  tw_pid="$(cat "$tw_pidf" 2>/dev/null || true)"
  if [ -n "$tw_pid" ] && kill -0 "$tw_pid" 2>/dev/null; then
    tag "kill tmux-watchdog (pid $tw_pid)"
    [ "$DRY" = 0 ] && { kill -TERM "$tw_pid" 2>/dev/null || true; sleep 1; kill -KILL "$tw_pid" 2>/dev/null || true; rm -f "$tw_pidf"; }
  else
    [ "$DRY" = 0 ] && rm -f "$tw_pidf"
  fi
fi

# 3b''. chrome-supervisor, observer, intake-poller (detached nohup daemons that
# cleanup did not handle before 2026-06-01, so they leaked past a cleanup/reset).
for _d in chrome-supervisor observer intake-poller; do
  _pidf="$TEAM_DIR/$_d.pid"
  if [ -f "$_pidf" ]; then
    _pid="$(cat "$_pidf" 2>/dev/null || true)"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      tag "kill $_d (pid $_pid)"
      [ "$DRY" = 0 ] && { kill -TERM "$_pid" 2>/dev/null || true; sleep 1; kill -KILL "$_pid" 2>/dev/null || true; rm -f "$_pidf"; }
    else
      [ "$DRY" = 0 ] && rm -f "$_pidf"
    fi
  fi
done

# 3c. Dashboard server (if launch-team.sh started one for this clone's team).
db_pidf="$TEAM_DIR/dashboard.pid"
if [ -f "$db_pidf" ]; then
  db_pid="$(cat "$db_pidf" 2>/dev/null || true)"
  if [ -n "$db_pid" ] && kill -0 "$db_pid" 2>/dev/null \
     && ps -p "$db_pid" -o args= 2>/dev/null | grep -q '[d]ashboard/server/server.py'; then
    tag "kill dashboard (pid $db_pid)"
    [ "$DRY" = 0 ] && { kill -TERM "$db_pid" 2>/dev/null || true; sleep 1; kill -KILL "$db_pid" 2>/dev/null || true; rm -f "$db_pidf" "$TEAM_DIR/dashboard.url"; }
  else
    [ "$DRY" = 0 ] && rm -f "$db_pidf" "$TEAM_DIR/dashboard.url"
  fi
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
if [ -d "$TEAM_DIR" ]; then
  tag "remove .team/ (ledger, prompts, evidence, active)"
  [ "$DRY" = 0 ] && rm -rf "$TEAM_DIR"
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

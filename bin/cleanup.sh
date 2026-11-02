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
# shellcheck source=bin/lib/pid-identity.sh
. "$repo/bin/lib/pid-identity.sh" || exit 1

force=0; purge=0
for a in "$@"; do case "$a" in
  --force) force=1 ;;
  --purge) purge=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a (try --help)" >&2; exit 2 ;;
esac; done
DRY=1; [ "$force" = 1 ] && DRY=0
# Role tripwire (mirrors reset.sh): a team role session must not --force-clean
# the run it belongs to. Dry runs stay allowed anywhere (read-only).
if [ "$DRY" = 0 ] && [ -n "${ORCH_HOME:-}" ] && [ "${RESET_CONFIRM:-}" != "yes" ]; then
  echo "cleanup: refusing --force — this shell looks like a team role session (ORCH_HOME is set)." >&2
  echo "  Run from an operator shell, or set RESET_CONFIRM=yes if this is deliberate." >&2
  exit 96
fi
tag(){ [ "$DRY" = 1 ] && printf '[would] %s\n' "$*" || printf '[done]  %s\n' "$*"; }

descendants(){ local p c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
killtree(){ # $* pids: TERM then KILL the process groups/pids (no-op in dry run)
  [ "$DRY" = 1 ] && return 0
  local p; for p in "$@"; do kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true; done
  sleep 1
  for p in "$@"; do kill -KILL "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true; done
}
# killtree_verified <root> <glob>... : killtree for a root pid read from a FILE (.team/active).
# The root is re-verified with proc_pid_is_run_daemon before the delayed SIGKILL (it may have exited
# on TERM and its number been reused in the second between), and a descendant is SIGKILLed only if it
# still carries this run's environment.
killtree_verified() {
  [ "$DRY" = 1 ] && return 0
  local root="$1" p d; shift
  d="$(descendants "$root")"
  kill -TERM "-$root" 2>/dev/null || kill -TERM "$root" 2>/dev/null || true
  for p in $d; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 1
  if proc_pid_is_run_daemon "$root" "$@"; then
    kill -KILL "-$root" 2>/dev/null || kill -KILL "$root" 2>/dev/null || true
  elif [ ! -d "/proc/$root" ]; then
    # The root exited on TERM. Its group can still hold members that ignored TERM (orphans not in
    # the descendant list). A process-group id is not reused while any member is alive, so a group
    # with this number is still the verified root's: SIGKILL it, as the old code did unconditionally.
    kill -KILL "-$root" 2>/dev/null || true
  fi
  for p in $d; do proc_pid_has_run_env "$p" && { kill -KILL "$p" 2>/dev/null || true; }; done
}
# reap_pidfile_daemon <name>: one of this run's pidfile daemons, gated like panic.sh's _reap_daemon.
# A refused pid gets one line naming pid, file and why; the pidfile is ours ($TEAM_DIR) and stale.
reap_pidfile_daemon() {
  local name="$1" pidf="$TEAM_DIR/$1.pid" globs=()
  [ -f "$pidf" ] || return 0
  mapfile -t globs < <(proc_run_daemon_globs "$name")
  if proc_pidfile_verdict "$pidf" "${globs[@]}"; then
    tag "kill $name (pid $PM_PID)"
    [ "$DRY" = 1 ] && return 0
    kill -TERM "$PM_PID" 2>/dev/null || true
    pkill -TERM -P "$PM_PID" 2>/dev/null || true
    sleep 1
    # Re-verify before escalating: a daemon that exited on TERM leaves a number that can be reused.
    if proc_pid_is_run_daemon "$PM_PID" "${globs[@]}"; then
      pkill -KILL -P "$PM_PID" 2>/dev/null || true
      kill -KILL "$PM_PID" 2>/dev/null || true
    fi
  elif [ "$PM_WHY" != "not running" ]; then
    tag "skip $name: pid $PM_PID from $pidf $PM_WHY; not signalled, pidfile removed"
  fi
  [ "$DRY" = 0 ] && rm -f "$pidf"
  return 0
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
    # This run's claude only (program position claude + this run's environ): the old args grep for
    # "claude" passed any process mentioning it, and the kill is a PROCESS-GROUP kill.
    if proc_pid_is_run_daemon "$pid" claude; then
      tag "reap recorded role '$role' (pid $pid)"; killtree_verified "$pid" claude
    elif [ -d "/proc/$pid" ]; then
      tag "skip recorded role '$role': pid $pid from $TEAM_DIR/active is alive but not this run's claude; not signalled"
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

# 3b. Pidfile daemons: api-watchdog, tmux-watchdog (May-2026: detects a dead tmux server),
# compaction-watchdog, host-ram-watchdog, disk-tmp-watchdog,
# chrome-supervisor, observer, intake-poller (detached nohup daemons that cleanup did not handle
# before 2026-06-01, so they leaked past a cleanup/reset; the host-ram/disk-tmp
# resource watchdogs were missing from this list until 2026-07-20). pkill -P reaps each daemon's
# backgrounded sleep child, which holds the per-TEAM_DIR flock fd and would otherwise block a
# relaunch for one INTERVAL. Every pid is gated by reap_pidfile_daemon.
for _d in api-watchdog tmux-watchdog compaction-watchdog host-ram-watchdog disk-tmp-watchdog \
          chrome-supervisor observer intake-poller; do
  reap_pidfile_daemon "$_d"
done

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

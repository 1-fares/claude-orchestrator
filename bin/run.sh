#!/usr/bin/env bash
# run.sh: one command to start (or attach) a run.
#
# Default (no args): allocate a fresh TEAM_RUN_ID, start the orchestrator, and
# attach. The orchestrator then asks you for the working tree and goal IN THE
# SESSION (visible, recorded, recoverable), so your input is part of the
# transcript, not a dead shell prompt.
#
# Per-run isolation: each invocation gets its own TEAM_RUN_ID and therefore its
# own bus port, tmux session, and state dir, so several parallel teams in this
# clone do not collide. Pre-set TEAM_RUN_ID=<id> to address a specific run.
#
# Recovery is built in. On start, run.sh discovers any live runs on the team
# tmux socket and offers to ATTACH (closing a terminal only detaches; the team
# keeps running) or start a NEW parallel run.
#
# Power / scripted use (skips the in-session questions):
#   bin/run.sh "what to build"            # inline goal, uses saved/this-clone target
#   bin/run.sh ~/projects/app             # set target; orchestrator asks the goal
#   bin/run.sh ~/projects/app "what"      # target + inline goal
#   bin/run.sh --dir PATH ["what"]
#   bin/run.sh --retarget                 # forget the saved target
#   TEAM_RUN_ID=<id> bin/run.sh ...       # operate on a specific run

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Per-run isolation: allocate a unique run-id if not given. Spawned children
# inherit TEAM_RUN_ID via env so every lifecycle script targets this run.
: "${TEAM_RUN_ID:=r$(date +%s)$$}"
export TEAM_RUN_ID
. "$repo/bin/team-env.sh"
conf="$repo/project.conf"

dir_arg=""; retarget=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir|-C) dir_arg="${2:-}"; [ -n "$dir_arg" ] || { echo "--dir needs a path" >&2; exit 2; }; shift 2 ;;
    --retarget) retarget=1; shift ;;
    --) shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [ -z "$dir_arg" ] && [ -n "${1:-}" ]; then
  case "$1" in
    /*|~|"~/"*|./*|../*) dir_arg="$1"; shift ;;
    *) [ -e "$1" ] && { dir_arg="$1"; shift; } ;;
  esac
fi
want_arg="${1:-}"
[ "$retarget" = 1 ] && rm -f "$conf"

resolve_target() {
  local wd="$1"
  case "$wd" in "~") wd="$HOME" ;; "~/"*) wd="$HOME/${wd#\~/}" ;; esac
  if [ -e "$wd" ] && [ ! -d "$wd" ]; then echo "not a directory: $wd" >&2; return 2; fi
  if [ -d "$wd/.git" ]; then
    WORKDIR="$(cd "$wd" && pwd)"; EXISTING=1; echo "Using existing repo: $WORKDIR"
  elif [ -d "$wd" ] && [ -n "$(ls -A "$wd" 2>/dev/null)" ]; then
    if [ -t 0 ]; then
      read -rp "$wd is not a git repo. Init git there so the team can use it? [y/N] " g
      case "$g" in
        y|Y) ( cd "$wd" && git init -q && { git add -A 2>/dev/null || true
                 git commit -qm "init (orchestrator)" 2>/dev/null \
                   || git -c user.email=orchestrator@local -c user.name=orchestrator commit -qm init --allow-empty; } )
             WORKDIR="$(cd "$wd" && pwd)"; EXISTING=1 ;;
        *) echo "Cannot proceed without git (scope checks and worktrees need it)." >&2; return 1 ;;
      esac
    else
      echo "$wd is not a git repo and there is no terminal to confirm. git init it first." >&2; return 2
    fi
  else
    "$repo/bin/new-project.sh" "$wd" >/dev/null || { echo "could not create repo at $wd" >&2; return 2; }
    WORKDIR="$(cd "$wd" && pwd)"; EXISTING=0; echo "Created new repo: $WORKDIR"
  fi
}

# --- 0. Recovery preflight: discover any live runs in this clone --------------
live=$(command tmux -L "$TEAM_TMUX" list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^orch-' || true)
if [ -n "$live" ]; then
  n=$(printf '%s\n' "$live" | wc -l)
  if [ -t 0 ]; then
    if [ "$n" -eq 1 ]; then
      echo "A run is live: $live"
      echo "  (Closing a terminal only detaches; the team keeps running. Reattach to resume.)"
      read -rp "[a]ttach / [s]tart a new parallel run / [q]uit? [a] " ans
      case "${ans:-a}" in
        s|S) : ;;
        q|Q) exit 0 ;;
        *)   exec "$repo/bin/attach.sh" "$live" ;;
      esac
    else
      echo "$n runs are live:"
      printf '%s\n' "$live" | sed 's/^/  /'
      read -rp "Session to attach (Enter = start a new parallel run): " sel
      [ -n "$sel" ] && exec "$repo/bin/attach.sh" "$sel"
    fi
  else
    echo "Live run(s):" >&2; printf '%s\n' "$live" | sed 's/^/  /' >&2
    echo "(Non-interactive; starting a new parallel run as $TEAM_RUN_ID. Attach an existing one with: bin/attach.sh <session>)" >&2
  fi
fi

# --- 1. Optional target/goal from args (power path; skips in-session questions) -
WORKDIR=""; EXISTING=0
[ -f "$conf" ] && . "$conf"
if [ -n "$dir_arg" ]; then
  resolve_target "$dir_arg" || exit $?
  { printf 'WORKDIR=%q\n' "$WORKDIR"; printf 'EXISTING=%q\n' "$EXISTING"; } > "$conf"
  echo "(Saved as this clone's target; the orchestrator will offer it as the default.)"
fi

goal_file=""
if [ -n "$want_arg" ]; then
  gname="goal-$(date +%H%M%S)"
  wd_arg="${WORKDIR:-}"; [ "$wd_arg" = "$repo" ] && wd_arg=""
  "$repo/bin/new-goal.sh" --name "$gname" --workdir "$wd_arg" --want "$want_arg" >/dev/null
  goal_file="goals/$gname.md"
  echo "goal: $goal_file"
fi

# --- 2. Launch the orchestrator (elicits the goal in-session if none given) ---
"$repo/bin/start-orchestrator.sh" ${goal_file:+"$goal_file"} >/dev/null
if [ -n "$goal_file" ]; then
  echo "Orchestrator starting (run $TEAM_RUN_ID, session $TEAM_SESSION) with goal $goal_file."
else
  echo "Orchestrator starting (run $TEAM_RUN_ID, session $TEAM_SESSION). It will ask you for the working tree and goal in the session."
fi
if [ -t 1 ]; then sleep 1; exec "$repo/bin/attach.sh"; else echo "Attach with: TEAM_RUN_ID=$TEAM_RUN_ID bin/attach.sh"; fi

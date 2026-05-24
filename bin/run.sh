#!/usr/bin/env bash
# run.sh: one command to start (or recover) a run.
#
# Default (no args): start the orchestrator and attach you. The orchestrator then
# asks you for the working tree and goal IN THE SESSION (visible, recorded,
# recoverable), so your input is part of the transcript, not a dead shell prompt.
#
# Recovery is built in. On start, run.sh:
#   - if a run is already live: offers to ATTACH (closing a terminal only detaches,
#     the team keeps running) or RESTART fresh;
#   - else, if a previous run left leftovers (a misfire, ctrl-d, orphans): offers
#     to clean them first via bin/cleanup.sh (which only ever touches THIS clone's
#     team, never your other Claude sessions).
#
# Power / scripted use (skips the in-session questions):
#   bin/run.sh "what to build"            # inline goal; uses the saved/this-clone target
#   bin/run.sh ~/projects/app             # set the target, orchestrator asks the goal
#   bin/run.sh ~/projects/app "what"      # target + inline goal
#   bin/run.sh --dir PATH ["what"]        # explicit target form
#   bin/run.sh --retarget                 # forget the saved target

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
# A bare first argument that looks like a path is the target; otherwise it's the goal.
if [ -z "$dir_arg" ] && [ -n "${1:-}" ]; then
  case "$1" in
    /*|~|"~/"*|./*|../*) dir_arg="$1"; shift ;;
    *) [ -e "$1" ] && { dir_arg="$1"; shift; } ;;
  esac
fi
want_arg="${1:-}"
[ "$retarget" = 1 ] && rm -f "$conf"

# resolve_target <path>: sets WORKDIR + EXISTING, or returns non-zero with a message.
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

# --- 0. Recovery preflight: reattach, restart, or clean leftovers --------------
if command tmux -L "$TEAM_TMUX" has-session -t "$TEAM_SESSION" 2>/dev/null; then
  if [ -t 0 ]; then
    echo "A run is already live in tmux session '$TEAM_SESSION'."
    echo "  (Closing a terminal only detaches; the team keeps running. Reattach to resume.)"
    read -rp "[a]ttach / [r]estart fresh / [q]uit? [a] " ans
    case "${ans:-a}" in
      r|R) "$repo/bin/cleanup.sh" --force --purge >/dev/null && echo "cleaned; starting fresh." ;;
      q|Q) exit 0 ;;
      *)   exec "$repo/bin/attach.sh" ;;
    esac
  else
    echo "A run is already live. attach: bin/attach.sh   restart: bin/cleanup.sh --force && bin/run.sh" >&2; exit 1
  fi
else
  # No live session; check for leftovers from a misfired/ended run.
  if "$repo/bin/cleanup.sh" 2>/dev/null | grep -q '\[would\]'; then
    if [ -t 0 ]; then
      echo "Leftovers from a previous run were found:"
      "$repo/bin/cleanup.sh" 2>/dev/null | grep -E '\[would\]|LEFT RUNNING|NOTE:' | sed 's/^/  /'
      read -rp "Clean this clone's leftovers before starting? [Y/n] " c
      case "${c:-y}" in n|N) : ;; *) "$repo/bin/cleanup.sh" --force --purge >/dev/null && echo "cleaned." ;; esac
    fi
  fi
fi

# --- 1. Optional target/goal from args (power path; skips the in-session questions)
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

# --- 2. Launch the orchestrator (it elicits the goal in-session if none given) ---
"$repo/bin/start-orchestrator.sh" ${goal_file:+"$goal_file"} >/dev/null
if [ -n "$goal_file" ]; then
  echo "Orchestrator starting with goal $goal_file."
else
  echo "Orchestrator starting. It will ask you for the working tree and goal in the session."
fi
if [ -t 1 ]; then sleep 1; exec "$repo/bin/attach.sh"; else echo "Attach with: bin/attach.sh"; fi

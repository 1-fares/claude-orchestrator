#!/usr/bin/env bash
# run.sh: one command to start a run. Sets up the target project (new or
# existing), writes the goal brief, starts the team in one tmux session, and
# drops you into the orchestrator. The target is remembered per clone (in
# project.conf), so repeat runs only ask for the goal.
#
# Usage:
#   bin/run.sh                          # interactive (asks target on first run, then goal)
#   bin/run.sh "what to build"          # inline goal, uses the saved target
#   bin/run.sh ~/projects/app           # set the target (a path), then ask the goal
#   bin/run.sh ~/projects/app "what"    # target + inline goal
#   bin/run.sh --dir PATH ["what"]      # explicit target form
#   bin/run.sh --retarget               # forget the saved target
#
# Target resolution (a given path, or the first-run prompt):
#   - existing git repo      -> used as-is
#   - a path that does not exist -> created as a new git repo
#   - existing non-git dir   -> offered a `git init` (the team needs git)

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

# 0. Active run? offer to reset.
if command tmux -L "$TEAM_TMUX" has-session -t "$TEAM_SESSION" 2>/dev/null; then
  if [ -t 0 ]; then
    read -rp "A team session is already running. Reset it and start fresh? [y/N] " a
    case "$a" in y|Y) "$repo/bin/reset.sh" >/dev/null ;; *) echo "Kept it. Attach: bin/attach.sh"; exit 0 ;; esac
  else
    echo "A team session is already running. attach: bin/attach.sh  reset: bin/reset.sh" >&2; exit 1
  fi
fi

# 1. Target: from --dir/path arg, else saved, else ask.
WORKDIR=""; EXISTING=0
[ -f "$conf" ] && . "$conf"
if [ -n "$dir_arg" ]; then
  resolve_target "$dir_arg" || exit $?
  { printf 'WORKDIR=%q\n' "$WORKDIR"; printf 'EXISTING=%q\n' "$EXISTING"; } > "$conf"
  echo "(Saved as this clone's target; future runs reuse it. Change with --dir or --retarget.)"
elif [ -z "${WORKDIR:-}" ]; then
  echo "First run in this clone. Which code should the team work on?"
  echo "  - path to an EXISTING project, or a NEW path to create,"
  echo "  - or leave blank to build inside this clone (greenfield)."
  read -rp "Path: " wd
  if [ -z "$wd" ]; then WORKDIR="$repo"; EXISTING=0; else resolve_target "$wd" || exit $?; fi
  { printf 'WORKDIR=%q\n' "$WORKDIR"; printf 'EXISTING=%q\n' "$EXISTING"; } > "$conf"
  echo "(Saved target to project.conf; future runs skip this.)"
else
  echo "Target: $WORKDIR"
fi

# 2. The goal.
if [ -n "$want_arg" ]; then
  gname=""; gwant="$want_arg"; gnotes=""; gteam=""
else
  read -rp "Short name for this goal (blank = auto): " gname
  echo "What do you want built or changed? (end with an empty line)"
  gwant="$(while IFS= read -r l; do [ -z "$l" ] && break; printf '%s\n' "$l"; done)"
  read -rp "Constraints / must-haves (optional): " gnotes
  read -rp "Team hint (optional): " gteam
fi
[ -n "$gwant" ] || { echo "a goal description is required" >&2; exit 1; }
gname="$(printf '%s' "${gname:-goal-$(date +%H%M%S)}" | tr ' ' '-')"
[ -e "$repo/goals/$gname.md" ] && gname="$gname-$(date +%H%M%S)"

# 3. Write the goal brief (blank workdir => this clone). Reuse new-goal.sh.
wd_arg="$WORKDIR"; [ "$WORKDIR" = "$repo" ] && wd_arg=""
args=(--name "$gname" --workdir "$wd_arg" --want "$gwant")
[ -n "$gnotes" ] && args+=(--notes "$gnotes")
[ -n "$gteam" ]  && args+=(--team "$gteam")
"$repo/bin/new-goal.sh" "${args[@]}" >/dev/null
echo "goal: goals/$gname.md"

# 4. Start the team and drop into the orchestrator.
"$repo/bin/start-orchestrator.sh" "goals/$gname.md" >/dev/null
echo "Team session started. You will land in the orchestrator; Ctrl-b/your-prefix <n> for roles; say 'go'."
if [ -t 1 ]; then sleep 1; exec "$repo/bin/attach.sh"; else echo "Attach with: bin/attach.sh"; fi

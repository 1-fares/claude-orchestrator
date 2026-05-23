#!/usr/bin/env bash
# run.sh: one command to start a run. Sets up the target project (new or
# existing), writes the goal brief, starts the team in one tmux session, and
# drops you into the orchestrator. The target is remembered per clone (in
# project.conf), so repeat runs only ask for the goal.
#
# Usage:
#   bin/run.sh                  # interactive (asks the goal)
#   bin/run.sh "what to build"  # inline goal, uses the saved target
#   bin/run.sh --retarget       # change which project this clone drives
#
# First run in a clone also asks which code to work on:
#   - a path to an EXISTING project (used as-is), or
#   - a NEW path (created as a git repo), or
#   - blank to build inside this clone (greenfield).

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
conf="$repo/project.conf"

[ "${1:-}" = "--retarget" ] && { rm -f "$conf"; shift; echo "Target cleared; will ask again."; }
want_arg="${1:-}"

# 0. Active run? offer to reset (so a leftover session never blocks a new run).
if command tmux -L "$TEAM_TMUX" has-session -t "$TEAM_SESSION" 2>/dev/null; then
  if [ -t 0 ]; then
    read -rp "A team session is already running. Reset it and start fresh? [y/N] " a
    case "$a" in y|Y) "$repo/bin/reset.sh" >/dev/null ;; *) echo "Kept it. Attach: bin/attach.sh"; exit 0 ;; esac
  else
    echo "A team session is already running. attach: bin/attach.sh  reset: bin/reset.sh" >&2; exit 1
  fi
fi

# 1. Target project: ask once per clone, then remember.
WORKDIR=""; EXISTING=0
[ -f "$conf" ] && . "$conf"
if [ -z "${WORKDIR:-}" ]; then
  echo "First run in this clone. Which code should the team work on?"
  echo "  - path to an EXISTING project, or a NEW path to create,"
  echo "  - or leave blank to build inside this clone (greenfield)."
  read -rp "Path: " wd
  if [ -z "$wd" ]; then
    WORKDIR="$repo"
  else
    case "$wd" in "~") wd="$HOME" ;; "~/"*) wd="$HOME/${wd#\~/}" ;; esac
    if [ -d "$wd/.git" ]; then
      WORKDIR="$(cd "$wd" && pwd)"; EXISTING=1; echo "Using existing repo: $WORKDIR"
    elif [ -e "$wd" ]; then
      read -rp "$wd exists but is not a git repo. Init git there so the team can use it? [y/N] " g
      case "$g" in
        y|Y) ( cd "$wd" && git init -q && { git add -A 2>/dev/null || true; git commit -qm "init (orchestrator)" 2>/dev/null \
                || git -c user.email=orchestrator@local -c user.name=orchestrator commit -qm init --allow-empty; } )
             WORKDIR="$(cd "$wd" && pwd)"; EXISTING=1 ;;
        *) echo "Cannot proceed without git (scope checks and worktrees need it)." >&2; exit 1 ;;
      esac
    else
      "$repo/bin/new-project.sh" "$wd" >/dev/null; WORKDIR="$(cd "$wd" && pwd)"; echo "Created new repo: $WORKDIR"
    fi
  fi
  { printf 'WORKDIR=%q\n' "$WORKDIR"; printf 'EXISTING=%q\n' "$EXISTING"; } > "$conf"
  echo "(Saved this clone's target to project.conf; future runs skip this. Change it with: bin/run.sh --retarget)"
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
echo "Team session started. You will land in the orchestrator; Ctrl-b <n> switches to roles; say 'go'."
if [ -t 1 ]; then sleep 1; exec "$repo/bin/attach.sh"; else echo "Attach with: bin/attach.sh"; fi

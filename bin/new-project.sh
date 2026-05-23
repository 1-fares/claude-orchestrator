#!/usr/bin/env bash
# new-project.sh: scaffold a brand-new target project directory as a git repo
# with an initial commit, ready to be driven by the team via --workdir.
# (check-scope and worktrees need a git repo with at least one commit.)
#
# Usage: bin/new-project.sh <dir>

set -euo pipefail

dir="${1:?usage: new-project.sh <dir>}"
case "$dir" in
  "~")    dir="$HOME" ;;
  "~/"*)  dir="$HOME/${dir#~/}" ;;
esac

if [ -d "$dir/.git" ]; then
  echo "already a git repo: $(cd "$dir" && pwd)"; exit 0
fi
if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
  echo "exists and is not an empty dir (and not a git repo): $dir" >&2; exit 1
fi

mkdir -p "$dir"
git -C "$dir" init -q
git -C "$dir" commit -q --allow-empty -m init 2>/dev/null \
  || git -C "$dir" -c user.email=orchestrator@local -c user.name=orchestrator \
       commit -q --allow-empty -m init

abs="$(cd "$dir" && pwd)"
echo "created project: $abs"
echo "next: bin/new-goal.sh   (point its working tree at $abs)"

#!/usr/bin/env bash
# worktree.sh: create or remove a git worktree + branch per implementer, so
# parallel implementers never edit the same tree. Run from inside the target
# codebase. The orchestrator (or launcher) calls `add`, then launches the
# implementer with --workdir <printed-path>; the integrator merges branch
# unit/<unit> and calls `remove` when done.
#
# Usage:
#   bin/worktree.sh add <unit> [base-ref]   # prints the new worktree path
#   bin/worktree.sh remove <unit>
#   bin/worktree.sh list

set -euo pipefail

cmd="${1:-}"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git tree: $PWD" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
name="$(basename "$root")"

case "$cmd" in
  add)
    unit="${2:?usage: worktree.sh add <unit> [base-ref]}"
    base="${3:-HEAD}"
    path="$(dirname "$root")/${name}-wt-${unit}"
    branch="unit/${unit}"
    [ -e "$path" ] && { echo "worktree path exists: $path" >&2; exit 1; }
    git worktree add -b "$branch" "$path" "$base" >&2
    echo "$path"   # stdout: the path, so the caller can use it as --workdir
    ;;
  remove)
    unit="${2:?usage: worktree.sh remove <unit>}"
    path="$(dirname "$root")/${name}-wt-${unit}"
    git worktree remove "$path" 2>/dev/null || git worktree remove --force "$path"
    echo "removed worktree $path (branch unit/$unit kept for history)"
    ;;
  list)
    git worktree list
    ;;
  *)
    echo "usage: worktree.sh add|remove|list <unit> [base-ref]" >&2; exit 1
    ;;
esac

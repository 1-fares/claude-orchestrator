#!/usr/bin/env bash
# worktree.sh: create or remove a git worktree + branch per implementer, so
# parallel implementers never edit the same tree. Run from inside the target
# codebase. The orchestrator (or launcher) calls `add`, then launches the
# implementer with --workdir <printed-path>; the integrator merges branch
# unit/<unit> and calls `remove` when done.
#
# Usage:
#   bin/worktree.sh add <unit> [base-ref]   # prints the new worktree path
#   bin/worktree.sh remove <unit> [--force]
#   bin/worktree.sh list
#
# remove refuses a worktree git will not remove (uncommitted or untracked changes, a
# lock) and prints git's reason. --force removes it anyway and DISCARDS those changes.

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
    unit="${2:?usage: worktree.sh remove <unit> [--force]}"
    force=()
    case "${3:-}" in
      '') ;;
      --force) force=(--force) ;;
      *) echo "usage: worktree.sh remove <unit> [--force]" >&2; exit 1 ;;
    esac
    path="$(dirname "$root")/${name}-wt-${unit}"
    # No silent --force fallback: it discarded the uncommitted work of a dirty worktree.
    if ! err="$(git worktree remove ${force[@]+"${force[@]}"} "$path" 2>&1)"; then
      echo "worktree.sh: git did not remove $path:" >&2
      printf '%s\n' "$err" | sed 's/^/  /' >&2
      [ "${#force[@]}" -eq 0 ] && echo "  Commit or discard the changes there, or run: worktree.sh remove $unit --force (discards them)" >&2
      exit 1
    fi
    echo "removed worktree $path (branch unit/$unit kept for history)"
    ;;
  list)
    git worktree list
    ;;
  *)
    echo "usage: worktree.sh add|remove|list <unit> [base-ref]" >&2; exit 1
    ;;
esac

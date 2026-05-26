#!/usr/bin/env bash
# launch-team.sh: spawn a team of Claude Code role-sessions in tmux, each
# joined to the inter-session (/is) bus. Driven by the orchestrator through its
# Bash tool, or run by hand.
#
# Usage:
#   bin/launch-team.sh [--workdir DIR] <goal-file> <role> [<role> ...]
#
# Examples:
#   # greenfield: build inside this clone (working tree = this repo)
#   bin/launch-team.sh goals/checkout-bug.md architect implementer1 tester1
#
#   # existing codebase: drive a project that lives elsewhere
#   bin/launch-team.sh --workdir ~/projects/some-app \
#       goals/repo-bugfix.md implementer1 tester1
#
# --workdir DIR   Directory the role sessions run in (default: this repo). Point
#                 it at the target codebase so roles edit the right tree and pick
#                 up that project's own CLAUDE.md. The orchestrator's CLAUDE.md,
#                 role file, and goal are read by absolute path regardless.
#
# A role name maps to a prompt file by stripping trailing digits:
#   implementer1, implementer2 -> roles/implementer.md
# The bare role name is the bus name, so the orchestrator addresses it directly:
#   /is s implementer1 ...
#
# Concurrent teams: to run more than one team at once, give each team its own bus
# by exporting INTER_SESSION_PORT before launching (and in the orchestrator
# session too). This launcher propagates INTER_SESSION_PORT and
# INTER_SESSION_IDLE_MINUTES into the spawned sessions. See README "Future work".
#
# Sessions start with --dangerously-skip-permissions so they run unattended.
# Only use this in a trusted local environment. Sessions are interactive (not
# `claude -p`): a print-mode session exits after one response and would kill a
# long-lived worker, so we keep them interactive and let the /is monitor hold
# them open between messages.
#
# Requires: tmux, and `claude` on PATH.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"   # sets TEAM_SESSION, TEAM_PORT, INTER_SESSION_PORT
# shellcheck source=bin/lib/team-spawn.sh
. "$repo/bin/lib/team-spawn.sh"  # model_for, ensure_role_file, pre_trust_workdir,
                                 # reap_dead_keep_live, start_one, start_api_watchdog
session="$TEAM_SESSION"
flags="--dangerously-skip-permissions"

usage() { echo "usage: $0 [--workdir DIR] <goal-file> <role> [<role> ...]" >&2; exit 1; }

# --- parse optional flags -------------------------------------------------
workdir="$repo"
while [ "${1:-}" = "--workdir" ] || [ "${1:-}" = "-w" ]; do
  [ "$#" -ge 2 ] || usage
  workdir="$2"; shift 2
done

[ "$#" -ge 2 ] || usage
goal="$1"; shift

if ! workdir_abs="$(cd "$workdir" 2>/dev/null && pwd)"; then
  echo "workdir is not a directory: $workdir" >&2; exit 1
fi

# Resolve the goal to an absolute path the spawned sessions can read.
goal_abs="$(resolve_goal "$goal")" || { echo "goal file not found: $goal" >&2; exit 1; }

command -v tmux >/dev/null   || { echo "tmux not installed" >&2; exit 1; }
command -v "${TEAM_ROLE_CMD:-claude}" >/dev/null || { echo "${TEAM_ROLE_CMD:-claude} not on PATH" >&2; exit 1; }

mkdir -p "$TEAM_DIR"

# Pre-trust the working tree so interactive roles don't stop at Claude Code's
# workspace-trust prompt (auto-skipped only in -p mode, which roles can't use).
pre_trust_workdir "$workdir_abs"

# Reap dead entries from a previous run so teardown never group-kills a recycled
# pid; keep live entries so a second launch can add roles to a running team.
reap_dead_keep_live

# Validate every role up front so a bad name never leaves a half-spawned team.
# A missing role file is created on the fly (see ensure_role_file), not an error.
for role in "$@"; do
  printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$' \
    || { echo "invalid bus name '$role' (must match ^[a-z0-9][a-z0-9-]{0,39}\$)" >&2; exit 1; }
  b="$(printf '%s' "$role" | sed 's/[0-9]*$//')"
  ensure_role_file "$b"
done

for role in "$@"; do
  start_one "$role"
  sleep 1   # stagger starts to ease the rate limit on a cold team
done

echo
echo "Roles running in tmux session '$session' on the team socket '$TEAM_TMUX'."
echo "Watch:  bin/team-status.sh    Attach:  tmux -L $TEAM_TMUX attach -t $session"

# Start the API watchdog (auto-recover transient Anthropic rate-limit / network
# stalls). Pure shell, no claude API calls, so cannot itself be rate-limited.
# Idempotent: a repeated launch does not start a second watchdog.
start_api_watchdog

# Start the B11 visual dashboard (second-screen view of the live run). Loopback-
# only, read-only, opt-out with DASHBOARD_DISABLED=1, port override with
# DASHBOARD_PORT. Idempotent like the watchdog. Torn down by stop-team.sh /
# panic.sh / cleanup.sh.
start_dashboard

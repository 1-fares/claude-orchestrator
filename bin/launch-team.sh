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

# --- M1: curated-role minimum gate ---------------------------------------
# A team run requires more than the workers the operator names on the CLI.
# The orchestrator is started separately by bin/start-orchestrator.sh; the
# user-communicator is the team's continuous liaison to the operator and must
# be on the bus for a healthy run. Both belong to the "curated minimum": the
# launcher warns when the role-list arg omits one, and (for communicator)
# auto-spawns at the end via start_communicator. The orchestrator-self-record
# is done by start-orchestrator.sh and asserted by the post-spawn sanity
# check below.
#
# Background: on 2026-05-26 the post-crash recovery flow relaunched 8 worker
# roles but skipped communicator because (a) the operator's role-list arg did
# not include it, and (b) at the time of the crash the launcher had no
# curated-minimum enforcement. This gate prevents recurrence.
CURATED_MINIMUM=(orchestrator communicator)
in_argv() {
  local needle="$1"; shift
  for r in "$@"; do [ "$r" = "$needle" ] && return 0; done
  return 1
}
for c in "${CURATED_MINIMUM[@]}"; do
  if in_argv "$c" "$@"; then continue; fi
  case "$c" in
    orchestrator)
      # Not spawned by us; start-orchestrator.sh owns it. Just warn so the
      # operator notices when an out-of-band orchestrator path was used.
      echo "WARN: curated role 'orchestrator' not in role list; start-orchestrator.sh should have it on the bus already"
      ;;
    communicator)
      if [ "${COMMUNICATOR_DISABLED:-0}" = "1" ]; then
        echo "WARN: curated role 'communicator' not in role list AND COMMUNICATOR_DISABLED=1; team will run without it"
      else
        echo "WARN: curated role 'communicator' not in role list; will be auto-included via the curated-minimum gate (bin/communicator.sh)"
      fi
      ;;
  esac
done
unset -f in_argv
# -------------------------------------------------------------------------

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

# Start the tmux watchdog (detect a dead tmux server fast, snapshot panes for
# forensics, ntfy on transitions, write CRASH-DETECTED.md). Added May 2026
# after a transient-scope cleanup killed an entire team in one second.
# Opt-out: TMUX_WATCHDOG_DISABLED=1. Idempotent.
start_tmux_watchdog

# Start the efficiency observer (periodic model-backed advice on growing/
# shrinking the team and right-sizing the host; recommends, never acts).
# Opt-out: OBSERVER_DISABLED=1. Idempotent.
start_observer

# Start the chrome-devtools supervisor (reap orphaned Chrome/MCP debris and fast
# un-wedge a role the api-watchdog has marked stuck on a hung chrome MCP call, by
# killing that role's Chrome so the MCP relaunches). Opt-out:
# CHROME_SUPERVISOR_DISABLED=1. Idempotent. No-op if bin/chrome-supervisor.sh absent.
start_chrome_supervisor

# Start the project's optional intake poller, if one is configured ($INTAKE_POLLER
# or <working-tree>/scripts/poller.py). Pings the orchestrator on new external
# traffic. Opt-out: INTAKE_POLLER_DISABLED=1. Idempotent. No-op if none exists.
start_intake_poller

# Start the B11 visual dashboard (second-screen view of the live run). Loopback-
# only, read-only, opt-out with DASHBOARD_DISABLED=1, port override with
# DASHBOARD_PORT. Idempotent like the watchdog. Torn down by stop-team.sh /
# panic.sh / cleanup.sh. The interactive prompt above lets the operator opt
# out at launch time; on N it exports DASHBOARD_DISABLED=1 so start_dashboard's
# own guard short-circuits without launching the server.
prompt_dashboard_choice
start_dashboard

# Bring up the user-communicator role (u28 wiring): the team's two-way liaison
# to the operator. Same shape as the dashboard: a soft default-Y prompt with
# COMMUNICATOR_DISABLED=1 env override, idempotent (skips when the bus already
# has a 'communicator' peer or when the tmux 'communicator' window exists).
prompt_communicator_choice() {
  if [ "${COMMUNICATOR_DISABLED:-0}" = "1" ]; then
    echo "communicator: skipped (COMMUNICATOR_DISABLED=1)"
    return 0
  fi
  if [ -t 0 ]; then
    printf 'Spawn the user-communicator role? [Y/n] '
  fi
  local ans=""
  if ! read -r -t 5 ans; then
    [ -t 0 ] && echo
    if [ -t 0 ]; then
      echo "communicator: accepted (timeout, default Y)"
    else
      echo "communicator: prompt skipped (non-tty, default Y)"
    fi
    return 0
  fi
  case "$ans" in
    [Nn]|[Nn][Oo])
      export COMMUNICATOR_DISABLED=1
      echo "communicator: declined; COMMUNICATOR_DISABLED=1 for this launch"
      ;;
    "")
      echo "communicator: accepted (default Y)"
      ;;
    *)
      echo "communicator: accepted ($ans)"
      ;;
  esac
}

start_communicator() {
  [ "${COMMUNICATOR_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/communicator.sh" ] || return 0

  # Idempotency: prefer the bus as the source of truth (the role file says the
  # bus enforces uniqueness). Fall back to the tmux window check inside
  # communicator.sh when the is-skill is not on disk. Either way a repeat
  # invocation is a no-op.
  local is_list="$HOME/.claude/skills/is/bin/list.py" existing_id=""
  if [ -f "$is_list" ]; then
    existing_id="$(python3 "$is_list" 2>/dev/null \
                     | awk '$1 == "communicator" {print $NF; exit}')"
    if [ -n "$existing_id" ]; then
      echo "communicator already running on the bus (peer id $existing_id)"
      return 0
    fi
  fi

  "$repo/bin/communicator.sh"
}

prompt_communicator_choice
start_communicator

# --- M1: post-spawn curated-role sanity check ----------------------------
# Walk the curated minimum and warn for each role that did not land in
# $TEAM_DIR/active after this launch. The format matches the brief so the
# operator can grep / parse it. This is a soft warning, not an error: the
# launcher still exits cleanly so it can be wired into automation.
if [ -f "$TEAM_DIR/active" ]; then
  for c in "${CURATED_MINIMUM[@]}"; do
    if ! awk -F'\t' -v r="$c" '$3 == r {found=1} END {exit !found}' \
            "$TEAM_DIR/active" 2>/dev/null; then
      echo "WARN: curated role '$c' not in active roster; spawn it with bin/add-role.sh $c"
    fi
  done
else
  echo "WARN: \$TEAM_DIR/active not present after spawn; curated-role sanity check skipped"
fi
# -------------------------------------------------------------------------

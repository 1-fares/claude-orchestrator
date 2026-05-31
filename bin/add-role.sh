#!/usr/bin/env bash
# add-role.sh: spawn ONE role into a LIVE team session (B9 dynamic team scaling,
# the "grow" half). Reuses the shared start_one spawn path so a mid-run role comes
# up identically to one launched at the start.
#
# Policy: the orchestrator may add freely up to the team-size cap, but every add
# is justified (decision-log line), surfaced (roster line + stdout notice), and,
# in autonomous runs, pushed over ntfy.
#
# Guardrails enforced here:
#   1. Soft cap: refuse once the per-run cap of live roles is reached. The cap is
#      operator-chosen at orchestrator start: enforce 12 (default), a custom
#      number, or uncapped. Resolution: MAX_TEAM_SIZE env > $TEAM_DIR/max-team-size
#      file > default 12; a value of none/unlimited/off/0 (or non-numeric) means
#      uncapped (the check is skipped). It is the real backstop against runaway
#      spawning when enforced.
#   2. No double-spawn: refuse a bus name that is already live.
#   3. Reuse-before-spawn: warn if an idle same-base role already exists, so the
#      orchestrator considers reusing it before growing the roster.
#   4. Justification: a decision-log + roster line is always written.
#
# Usage:
#   bin/add-role.sh [--workdir DIR] <goal-file> <role> [--task <brief>]
#                   [--reason "<why>"] [--auto-number] [--no-ntfy]
#
#   --workdir DIR    working tree the role operates on (default: this clone)
#   --task <brief>   path to a tasks/<unit>.md brief to assign; recorded in the
#                    decision-log. (The handoff itself goes over /is from the
#                    orchestrator; a shell script cannot authenticate to the bus.)
#   --reason "<why>" justification recorded in the decision-log (strongly advised)
#   --auto-number    treat <role> as a base and pick the next free <base>N
#   --no-ntfy        suppress the ntfy push even when NTFY_URL is set
#
# Refuses if no team session is live (use bin/launch-team.sh or bin/run.sh to
# start one). Targets ONLY this run's TEAM_SESSION; never another session.
#
# Requires: tmux, and `claude` on PATH (or TEAM_ROLE_CMD).

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"
# shellcheck source=bin/lib/team-spawn.sh
. "$repo/bin/lib/team-spawn.sh"
# shellcheck source=bin/lib/roster.sh
. "$repo/bin/lib/roster.sh"

session="$TEAM_SESSION"
flags="--dangerously-skip-permissions"

# Soft, per-run team-size cap. The operator chooses it at orchestrator start:
# enforce 12 (default), a custom number, or uncapped. Resolution precedence:
#   1. explicit MAX_TEAM_SIZE in the environment (one-off override on this call)
#   2. the per-run file $TEAM_DIR/max-team-size (what the orchestrator writes)
#   3. default 12
# A value of none / unlimited / off / 0, or anything non-numeric, means UNCAPPED.
# Echoes a positive integer to enforce, or empty for uncapped.
resolve_cap() {
  local v=""
  if [ -n "${MAX_TEAM_SIZE:-}" ]; then v="$MAX_TEAM_SIZE"
  elif [ -f "$TEAM_DIR/max-team-size" ]; then v="$(head -n1 "$TEAM_DIR/max-team-size" 2>/dev/null | tr -d '[:space:]')"
  else v="12"; fi
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    ''|none|uncapped|unlimited|off|0) echo "" ;;   # uncapped
    *[!0-9]*)                          echo "" ;;   # non-numeric -> uncapped (lenient)
    *)                                 echo "$v" ;;
  esac
}

usage() {
  echo "usage: $0 [--workdir DIR] <goal-file> <role> [--task <brief>] [--reason \"<why>\"] [--auto-number] [--no-ntfy]" >&2
  exit 2
}

workdir="$repo"; task_brief=""; reason=""; auto_number=0; no_ntfy=0
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir|-w) [ $# -ge 2 ] || usage; workdir="$2"; shift 2 ;;
    --task)       [ $# -ge 2 ] || usage; task_brief="$2"; shift 2 ;;
    --reason)     [ $# -ge 2 ] || usage; reason="$2"; shift 2 ;;
    --auto-number) auto_number=1; shift ;;
    --no-ntfy)    no_ntfy=1; shift ;;
    -h|--help)    sed -n '2,33p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do positional+=("$1"); shift; done ;;
    -*) echo "unknown arg: $1" >&2; usage ;;
    *)  positional+=("$1"); shift ;;
  esac
done
[ "${#positional[@]}" -eq 2 ] || usage
goal="${positional[0]}"; role="${positional[1]}"

command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }
command -v "${TEAM_ROLE_CMD:-claude}" >/dev/null || { echo "${TEAM_ROLE_CMD:-claude} not on PATH" >&2; exit 1; }

# A live team session is required: add-role GROWS a running team; it does not
# bootstrap one. This is the key difference from launch-team.sh.
if ! tmux has-session -t "$session" 2>/dev/null; then
  echo "no live team session '$session' on socket '$TEAM_TMUX'." >&2
  echo "add-role grows a RUNNING team. Start one first: bin/run.sh  (or bin/launch-team.sh)" >&2
  exit 1
fi

if ! workdir_abs="$(cd "$workdir" 2>/dev/null && pwd)"; then
  echo "workdir is not a directory: $workdir" >&2; exit 1
fi
goal_abs="$(resolve_goal "$goal")" || { echo "goal file not found: $goal" >&2; exit 1; }
[ -z "$task_brief" ] || [ -f "$task_brief" ] || { echo "task brief not found: $task_brief" >&2; exit 1; }

mkdir -p "$TEAM_DIR"
# Serialize the whole reap -> cap-check -> spawn -> record critical section against
# any concurrent add-role/retire-role, so two adds cannot both pass the cap or
# interleave writes to active. Held (fd 9) until this process exits. flock is
# util-linux; if it is somehow absent, proceed unlocked rather than dead-end.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$TEAM_DIR/.roster.lock"
  flock -w 30 9 || { echo "could not acquire roster lock within 30s (another add/retire running?)" >&2; exit 1; }
fi

# See truth before counting / double-spawn checks: drop dead entries, keep live.
reap_dead_keep_live

# Auto-number: treat the given name as a base and pick the next free <base>N.
if [ "$auto_number" -eq 1 ]; then
  base="$(printf '%s' "$role" | sed 's/[0-9]*$//')"
  [ -n "$base" ] || { echo "cannot auto-number an empty base from '$role'" >&2; exit 1; }
  role="$(next_role_number "$base")"
  echo "auto-numbered role -> $role"
fi

# Validate the (possibly auto-numbered) bus name.
printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$' \
  || { echo "invalid bus name '$role' (must match ^[a-z0-9][a-z0-9-]{0,39}\$)" >&2; exit 1; }

# Guardrail 2: no double-spawn of a live bus name.
if role_is_live "$role"; then
  echo "role '$role' is already live on this team; refusing to double-spawn." >&2
  echo "  (use --auto-number to add another instance, or pick a distinct name)" >&2
  exit 1
fi

# Guardrail 1: the soft cap (operator-chosen at start). Empty cap = uncapped, so
# the check is skipped entirely. The cap is the real backstop against runaway
# spawning when enforced.
cap="$(resolve_cap)"
if [ -n "$cap" ]; then
  live_now="$(live_role_count)"
  if [ "$live_now" -ge "$cap" ]; then
    echo "team is at the cap ($live_now live roles, cap $cap)." >&2
    echo "refusing to add '$role'. Retire a finished role first (bin/retire-role.sh)," >&2
    echo "raise the cap (echo N > $TEAM_DIR/max-team-size), or uncap it" >&2
    echo "(echo none > $TEAM_DIR/max-team-size, or MAX_TEAM_SIZE=none bin/add-role.sh ...)." >&2
    exit 1
  fi
fi

# Guardrail 3: reuse-before-spawn hint. A same-base role already live MIGHT be
# idle and able to take the work; surface it, do not block (orchestrator's call).
base_new="$(printf '%s' "$role" | sed 's/[0-9]*$//')"
same_base="$(live_roles | sed 's/[0-9]*$//' | grep -xF "$base_new" || true)"
if [ -n "$same_base" ]; then
  echo "note: a '$base_new' role is already on the team. If it is idle, consider" >&2
  echo "      reusing it (reassign over /is) before growing the roster." >&2
fi

pre_trust_workdir "$workdir_abs"

# Spawn the one role.
start_one "$role"

# Ensure the team's background daemons are running (all idempotent). Closes the
# gap where one was started disabled or died, AND it is the path that brings them
# back on a post-crash/restart recovery: the orchestrator re-adds roles via
# add-role, so this is where api-watchdog, tmux-watchdog, the observer, the
# chrome-supervisor, and any intake poller get re-ensured for the recovered run.
# (Previously only the api-watchdog was re-ensured here, so the others did not
# survive a recovery.)
start_api_watchdog || true
start_tmux_watchdog || true
start_observer || true
start_chrome_supervisor || true
start_intake_poller || true

# Justify + surface (always). Reason defaults to a generic note if not given.
# The role is already live and recorded in active (the teardown source of truth),
# so a ledger-write failure must not abort: warn and continue.
reason_txt="${reason:-no reason given}"
brief_txt=""; [ -n "$task_brief" ] && brief_txt=" brief: $task_brief"
decision_log_append "added $role (reason: $reason_txt;${brief_txt:- } via add-role)" \
  || echo "warning: could not write decision-log line (role IS live and recorded in active)" >&2
roster_append "+$role (added: $reason_txt)" \
  || echo "warning: could not write roster line (role IS live and recorded in active)" >&2

new_count="$(live_role_count)"
echo "added $role / now $new_count live role(s) (cap ${cap:-uncapped})"
if [ -n "$task_brief" ]; then
  echo "task brief recorded: $task_brief"
  echo "  hand it over the bus from the orchestrator: /is s $role --file $task_brief"
fi

# ntfy push (autonomous-mode roster-change notice). Plain POST, no action buttons.
if [ "$no_ntfy" -eq 0 ] && [ -n "${NTFY_URL:-}" ]; then
  curl -sS -m 5 -X POST \
    -H "Title: team grew: +$role" \
    -d "added $role (reason: $reason_txt). $new_count live role(s), cap ${cap:-uncapped}." \
    "$NTFY_URL" -o /dev/null 2>/dev/null \
    && echo "ntfy: roster-change push sent" \
    || echo "ntfy: push failed (non-fatal)" >&2
fi

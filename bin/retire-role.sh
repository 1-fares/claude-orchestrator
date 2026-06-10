#!/usr/bin/env bash
# retire-role.sh: graceful teardown of ONE role on a live team (B9 dynamic team
# scaling, the "shrink" half). Terminal: kills the role's session, frees a slot
# under the cap, and keeps the roster legible. For a role that is only
# temporarily idle, prefer `pause:` over the bus (free, instant resume, keeps
# context); retire is for a role whose job is done and will not recur.
#
# SAFETY (same hard rules as cleanup.sh / stop-team.sh):
#   - Operates ONLY on this run's TEAM_SESSION; never another tmux session.
#   - Kills ONLY the target role's recorded pid-group and window.
#   - Verifies the pid is still a claude process before signalling it, so a stale
#     active entry never group-kills a recycled, unrelated pid.
#   - Never touches the /is bus server (the team and orchestrator stay up; full
#     teardown is stop-team.sh's job).
#
# Never drops work: refuses if the role has in-flight units in the ledger, unless
# --force, which first re-files each as a `todo` (owner cleared) so the
# orchestrator can reassign it.
#
# Usage:
#   bin/retire-role.sh <role> [--reason "<why>"] [--force] [--no-graceful] [--no-ntfy]
#
#   --reason "<why>"  justification recorded in the decision-log (advised)
#   --force           retire even with in-flight units (re-files them as todo)
#   --no-graceful     skip the "stop and save" pane pass; TERM/KILL straight away
#   --no-ntfy         suppress the ntfy push even when NTFY_URL is set
#
# Requires: tmux.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"
# shellcheck source=bin/lib/roster.sh
. "$repo/bin/lib/roster.sh"

session="$TEAM_SESSION"
active="$TEAM_DIR/active"

# True only if window id $1 currently belongs to THIS run's session. Guards the
# window operations so a stale active entry (e.g. after a tmux server restart,
# when ids restart at @0) can never send-keys to, or kill, an unrelated window.
# The pid-group kill is guarded separately by kill -0 + is_claude, so a role with
# no matching window is still reaped by pid.
wid_in_session() {
  [ -n "${1:-}" ] || return 1
  tmux has-session -t "$session" 2>/dev/null || return 1
  tmux list-windows -t "$session" -F '#{window_id}' 2>/dev/null | grep -qx "$1"
}

# Recursively list a pid's descendants. claude's /is client is setsid'd into its
# OWN process group, so a leader process-group kill can miss it; we reap the
# descendant pids explicitly too, mirroring cleanup.sh rather than relying on the
# client to self-exit when its parent dies.
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

# Ownership proof, NOT just "is it a claude". A recorded pid can die and the OS
# can recycle that number to ANOTHER team's (or an /rc session's) claude; killing
# it by is_claude alone would hit the wrong session. Every role this run spawned
# carries ORCH_HOME=<this clone> and INTER_SESSION_PORT=<this run's bus port> in
# its environment (start_one exports both), and the per-run port is unique to this
# team, so that pair positively identifies our processes. Reading /proc/<pid>/environ
# also proves the pid is alive and ours. This is the guard before any kill; it
# works even when the role's window is gone (a HUP-surviving claude still has our
# environment), which a session-membership check alone could not cover.
owned_by_this_run() {
  local pid="$1" env
  [ -n "${pid:-}" ] && [ -r "/proc/$pid/environ" ] || return 1
  env="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)" || return 1
  printf '%s\n' "$env" | grep -qxF "ORCH_HOME=$repo" || return 1
  # The strong per-run discriminator is TEAM_RUN_ID (unique per run, exported into
  # every role by start_one). Prefer it: two runs that accidentally share a bus
  # port (a manual INTER_SESSION_PORT override) still differ by run id. Fall back
  # to the bus port only in legacy single-team mode (no TEAM_RUN_ID), where there
  # is one team per clone anyway.
  if [ -n "${TEAM_RUN_ID:-}" ]; then
    printf '%s\n' "$env" | grep -qxF "TEAM_RUN_ID=$TEAM_RUN_ID" || return 1
  else
    printf '%s\n' "$env" | grep -qxF "INTER_SESSION_PORT=$TEAM_PORT" || return 1
  fi
  return 0
}

usage() {
  echo "usage: $0 <role> [--reason \"<why>\"] [--force] [--no-graceful] [--no-ntfy]" >&2
  exit 2
}

role=""; reason=""; force=0; graceful=1; no_ntfy=0
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)      [ $# -ge 2 ] || usage; reason="$2"; shift 2 ;;
    --force)       force=1; shift ;;
    --no-graceful) graceful=0; shift ;;
    --no-ntfy)     no_ntfy=1; shift ;;
    -h|--help)     sed -n '2,28p' "$0"; exit 0 ;;
    -*) echo "unknown arg: $1" >&2; usage ;;
    *)  [ -z "$role" ] && role="$1" || { echo "unexpected arg: $1" >&2; usage; }; shift ;;
  esac
done
[ -n "$role" ] || usage
command -v tmux >/dev/null || { echo "tmux not installed" >&2; exit 1; }

[ -f "$active" ] || { echo "no active roster ($active); nothing to retire." >&2; exit 1; }

# Serialize against any concurrent add-role/retire-role (same lock add-role uses),
# so the read-match-kill-rewrite of active is not interleaved. Held until exit.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$TEAM_DIR/.roster.lock"
  flock -w 30 9 || { echo "could not acquire roster lock within 30s (another add/retire running?)" >&2; exit 1; }
fi

# Collect this role's recorded entries (there should be exactly one). Anything
# else stays untouched in the rewritten roster. `|| [ -n "$pid" ]` so a final
# line lacking a trailing newline is still read, not silently dropped.
matched=0
declare -a m_pids=() m_wids=()
while IFS=$'\t' read -r pid wid r || [ -n "${pid:-}" ]; do
  [ -n "${pid:-}" ] || continue
  if [ "$r" = "$role" ]; then
    matched=$((matched + 1)); m_pids+=("$pid"); m_wids+=("$wid")
  fi
done < "$active"

if [ "$matched" -eq 0 ]; then
  echo "role '$role' is not in the active roster; nothing to retire." >&2
  echo "  live roles: $(live_roles | paste -sd' ' -)" >&2
  exit 1
fi

# Never drop work: block on in-flight units unless --force (which re-files them).
mapfile -t inflight < <(in_flight_units_for_role "$role")
if [ "${#inflight[@]}" -gt 0 ]; then
  if [ "$force" -eq 0 ]; then
    echo "role '$role' has in-flight unit(s): ${inflight[*]}" >&2
    echo "refusing to retire (work would be dropped). Options:" >&2
    echo "  - reassign or finish the unit(s) first, then retire; or" >&2
    echo "  - bin/retire-role.sh $role --force   (re-files them as todo)" >&2
    exit 1
  fi
  # Re-file every in-flight unit BEFORE tearing the role down. If any re-file
  # fails, abort with the role untouched: tearing it down anyway would silently
  # drop that unit's work, which is exactly what --force must prevent.
  for u in "${inflight[@]}"; do
    if refile_unit "$u" "re-filed on forced retire of $role"; then
      echo "re-filed unit '$u' as todo (owner cleared)"
    else
      echo "ABORT: could not re-file in-flight unit '$u' in the ledger; retire would" >&2
      echo "       drop its work. Role '$role' left running. Fix the ledger and retry." >&2
      exit 1
    fi
  done
fi

# Capture each live leader's descendant pids NOW, before any kill: once a leader
# dies its children reparent to init and the tree can no longer be walked. These
# descendants (the /is client, MCP servers) belong to this role's confirmed-ours
# claude, so reaping them is safe and scoped.
declare -a desc_pids=()
for pid in "${m_pids[@]}"; do
  [ -n "${pid:-}" ] || continue
  if owned_by_this_run "$pid"; then
    while read -r d; do [ -n "$d" ] && desc_pids+=("$d"); done < <(descendants "$pid")
  fi
done

# (1) Graceful pass: ask the role to stop and save via its pane, then wait.
if [ "$graceful" -eq 1 ]; then
  for wid in "${m_wids[@]}"; do
    wid_in_session "$wid" || continue
    tmux send-keys -t "$wid" -l "stop: you are being retired; finish the current write and stop." 2>/dev/null \
      && tmux send-keys -t "$wid" Enter 2>/dev/null || true
  done
  sleep 4
fi

# (2) SIGTERM each recorded process group (only if still a claude process), then
# the captured descendants (and their own groups), so a setsid'd /is client dies.
for pid in "${m_pids[@]}"; do
  [ -n "${pid:-}" ] || continue
  if owned_by_this_run "$pid"; then
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    echo "TERM $role (pid $pid)"
  fi
done
for d in "${desc_pids[@]:-}"; do
  [ -n "${d:-}" ] || continue
  owned_by_this_run "$d" || continue   # skip a descendant pid recycled to a stranger
  kill -TERM "-$d" 2>/dev/null || true; kill -TERM "$d" 2>/dev/null || true
done
sleep 2

# (3) SIGKILL survivors (leaders + descendants), then close the windows (scoped
# to this session's wids).
for i in "${!m_pids[@]}"; do
  pid="${m_pids[$i]}"; wid="${m_wids[$i]}"
  if owned_by_this_run "$pid"; then
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    echo "KILL $role (pid $pid)"
  fi
  wid_in_session "$wid" && tmux kill-window -t "$wid" 2>/dev/null || true
done
for d in "${desc_pids[@]:-}"; do
  [ -n "${d:-}" ] || continue
  owned_by_this_run "$d" || continue   # skip a descendant pid recycled to a stranger
  kill -KILL "-$d" 2>/dev/null || true; kill -KILL "$d" 2>/dev/null || true
done

# (4) Verify the role is gone before recording the retire.
survivors=0
for pid in "${m_pids[@]}"; do
  [ -n "${pid:-}" ] || continue
  if owned_by_this_run "$pid"; then
    echo "WARNING: $role (pid $pid) still alive after KILL" >&2; survivors=$((survivors + 1))
  fi
done
if [ "$survivors" -gt 0 ]; then
  echo "retire of '$role' incomplete: $survivors process(es) survived; roster left unchanged." >&2
  exit 1
fi

# (5) Archive the role's health + audit + prompt to retired/<role>/.
retired_dir="$TEAM_DIR/retired/$role"
mkdir -p "$retired_dir"
[ -f "$TEAM_DIR/health/$role.json" ] && mv "$TEAM_DIR/health/$role.json" "$retired_dir/" 2>/dev/null || true
# Guarantee the live health file is gone even if the archive mv lost a race
# (a stale health/<role>.json otherwise inflates whatever reads the health dir as
# a live roster, e.g. the observer). Idempotent: a no-op when the mv already moved it.
rm -f "$TEAM_DIR/health/$role.json" 2>/dev/null || true
if [ -d "$TEAM_DIR/audit/api-watchdog" ]; then
  for af in "$TEAM_DIR/audit/api-watchdog/$role".*; do
    [ -e "$af" ] && mv "$af" "$retired_dir/" 2>/dev/null || true
  done
fi
[ -f "$TEAM_DIR/$role.prompt" ] && cp "$TEAM_DIR/$role.prompt" "$retired_dir/" 2>/dev/null || true
date +%FT%T%z > "$retired_dir/retired-at"

# (6) Remove the role's line(s) from active (rewrite excluding this role).
tmp="$active.$$"; : > "$tmp"
while IFS=$'\t' read -r pid wid r || [ -n "${pid:-}" ]; do
  [ -n "${pid:-}" ] || continue
  [ "$r" = "$role" ] && continue
  printf '%s\t%s\t%s\n' "$pid" "$wid" "$r" >> "$tmp"
done < "$active"
mv "$tmp" "$active"

# (7) Justify + surface.
reason_txt="${reason:-no reason given}"
note=""; [ "${#inflight[@]}" -gt 0 ] && note=" (re-filed in-flight: ${inflight[*]})"
decision_log_append "retired $role (reason: $reason_txt)$note"
roster_append "-$role (retired: $reason_txt)"

remaining="$(live_role_count)"
echo "retired $role / $remaining live role(s) remain"
echo "archived to: $retired_dir"

# ntfy push (autonomous-mode roster-change notice).
if [ "$no_ntfy" -eq 0 ] && [ -n "${NTFY_URL:-}" ]; then
  curl -sS -m 5 -X POST \
    -H "Title: team shrank: -$role" \
    -d "retired $role (reason: $reason_txt). $remaining live role(s) remain." \
    "$NTFY_URL" -o /dev/null 2>/dev/null \
    && echo "ntfy: roster-change push sent" \
    || echo "ntfy: push failed (non-fatal)" >&2
fi

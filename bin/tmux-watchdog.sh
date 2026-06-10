#!/usr/bin/env bash
# tmux-watchdog.sh: detect the team tmux server dying and surface it fast.
#
# Background. May 2026: a running team lost its entire tmux server in one
# second (systemd cleanup of every tmux-spawn-*.scope), taking all role
# processes with it. The bus, dashboard, and api-watchdog kept running
# (they were started detached via nohup), so from outside everything
# "looked fine" until someone tried to capture a pane. This watchdog
# closes that gap: it polls the team session, and if the session is
# gone but `$TEAM_DIR/active` still has entries, it treats that as a
# crash, writes a marker file, and pushes an ntfy notification.
#
# It does NOT auto-restart the team. Recovery still goes through the
# operator (or a higher-level supervisor) because it needs a clean
# decision: "resume this run-id" vs "start fresh" vs "investigate first".
# Cheap-and-correct beats clever-and-wrong here.
#
# Usage:
#   bin/tmux-watchdog.sh            # foreground (rare; for debugging)
#   started automatically by bin/lib/team-spawn.sh same shape as api-watchdog
#   stopped by bin/stop-team.sh / panic.sh / cleanup.sh
#
# Output:
#   $TEAM_DIR/health/tmux.json     {state: ok|crashed, last_seen, since}
#   $TEAM_DIR/audit/tmux.log       chronological events
#   $TEAM_DIR/tmux-watchdog.pid    pidfile
#   ntfy push on state transitions (if NTFY_URL is set)
#
# Snapshots (forensics):
#   Every SNAPSHOT_INTERVAL_S the watchdog captures each tmux window's
#   visible pane to $TEAM_DIR/snapshots/<window>.txt. If the team dies,
#   the last snapshot is the closest thing to a post-mortem.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"

interval=${TMUX_WATCHDOG_INTERVAL_S:-15}
snap_interval=${TMUX_WATCHDOG_SNAPSHOT_S:-60}

health_dir="$TEAM_DIR/health"
audit_dir="$TEAM_DIR/audit"
snap_dir="$TEAM_DIR/snapshots"
mkdir -p "$health_dir" "$audit_dir" "$snap_dir"

hf="$health_dir/tmux.json"
af="$audit_dir/tmux.log"
pidf="$TEAM_DIR/tmux-watchdog.pid"

# Already running? Refuse to double-start (idempotent). Verify the pid is
# actually a tmux-watchdog, not just any live pid: after a reboot or heavy
# churn the OS reuses pids, and a bare `kill -0` on a stale pidfile pointing at
# a reused, unrelated pid would false-positive and lock the watchdog out of
# ever restarting (observed 2026-05-31: stale pidfile -> "already running" ->
# no watchdog for hours). Match how team-spawn.sh's start guard checks it.
if [ -f "$pidf" ]; then
  prev=$(cat "$pidf" 2>/dev/null || echo 0)
  # $prev == $$ means the launcher (team-spawn start guard) already recorded
  # THIS process in the pidfile before our guard ran; treating it as a live
  # peer makes every launcher-started daemon exit at birth.
  if [ "$prev" != 0 ] && [ "$prev" != "$$" ] && kill -0 "$prev" 2>/dev/null \
       && ps -p "$prev" -o args= 2>/dev/null | grep -q 'tmux-watchdog'; then
    echo "tmux-watchdog already running (pid $prev)"
    exit 0
  fi
fi
echo $$ > "$pidf"
trap 'rm -f "$pidf"' EXIT

now() { date +%s; }
iso() { date -u -d "@${1:-$(now)}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

write_state() {
  local state="$1" last_seen="$2" since="$3"
  jq -nc \
    --arg state "$state" \
    --argjson last_seen "$last_seen" \
    --argjson since "$since" \
    --arg session "$TEAM_SESSION" \
    --arg run_id "${TEAM_RUN_ID:-legacy}" \
    '{state:$state, last_seen:$last_seen, since:$since, session:$session, run_id:$run_id}' \
    > "$hf"
}

notify() {
  [ -z "${NTFY_URL:-}" ] && return 0
  curl -s -m 5 -d "$1" "$NTFY_URL" >/dev/null 2>&1 || true
}

snapshot() {
  # Capture every window of $TEAM_SESSION to $snap_dir/<window_name>.txt
  command tmux -L "$TEAM_TMUX" has-session -t "$TEAM_SESSION" 2>/dev/null || return 0
  command tmux -L "$TEAM_TMUX" list-windows -t "$TEAM_SESSION" -F '#{window_id}'$'\t''#{window_name}' 2>/dev/null \
  | while IFS=$'\t' read -r wid name; do
      [ -n "$name" ] || continue
      command tmux -L "$TEAM_TMUX" capture-pane -t "$wid" -p -S -200 > "$snap_dir/$name.txt.tmp" 2>/dev/null \
        && mv "$snap_dir/$name.txt.tmp" "$snap_dir/$name.txt"
    done
}

active_has_entries() {
  # `$TEAM_DIR/active` carries one line per spawned role.
  # If it has any non-empty lines, the team is supposed to be running.
  [ -f "$TEAM_DIR/active" ] && [ -s "$TEAM_DIR/active" ] && grep -q '[^[:space:]]' "$TEAM_DIR/active"
}

prev_state=$(jq -r '.state // "unknown"' "$hf" 2>/dev/null || echo unknown)
since=$(jq -r '.since // 0' "$hf" 2>/dev/null || echo 0)
nowts=$(now)
[ "$since" = 0 ] && since=$nowts

last_snap=0

echo "$(iso) tmux-watchdog start: session=$TEAM_SESSION socket=$TEAM_TMUX interval=${interval}s snap=${snap_interval}s" >> "$af"
write_state "$prev_state" "$nowts" "$since"

# Self-heal the api-watchdog. It does real work (pane scans, sends keystrokes) and
# can die (crash, OOM, killed by stop-team during a partial restart); between
# launches nothing restarts it, and a dead api-watchdog means a transient API
# rate-limit stall halts the whole team silently (2026-06-01: it was down a full
# day after an orchestrator recovery). This tmux-watchdog is the robust always-on
# daemon (no API calls, minimal work, survives tmux death), so it is the natural
# supervisor-of-supervisor. Re-ensure quietly each loop; log + push only when it
# actually had to restart. Mirrors team-spawn.sh's start_api_watchdog idempotency.
ensure_api_watchdog() {
  [ "${API_WATCHDOG_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/api-watchdog.sh" ] || return 0
  # Liveness via the daemon's own flock (stale-proof), not the pidfile. A held
  # lock = a live daemon, so skip. This stops the respawn-storm that a stale or
  # missing pidfile caused once the flock guard made a relaunched start exit at
  # birth. The launcher does NOT write the pidfile; the daemon self-records after
  # winning the flock, so a doomed relaunch never clobbers it with a dead pid.
  local lk="$TEAM_DIR/api-watchdog.lock"
  if command -v flock >/dev/null 2>&1; then
    if ! ( exec 201>"$lk" && flock -n 201 ) 2>/dev/null; then return 0; fi
  else
    local pidf="$TEAM_DIR/api-watchdog.pid" oldpid
    if [ -f "$pidf" ]; then
      oldpid="$(cat "$pidf" 2>/dev/null || true)"
      if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
           && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'api-watchdog'; then
        return 0   # alive; nothing to do
      fi
    fi
  fi
  nohup "$repo/bin/api-watchdog.sh" >"$TEAM_DIR/api-watchdog.log" 2>&1 9>&- &
  echo "$(iso) SELF-HEAL: api-watchdog was down; restarted (pid $!)" >> "$af"
  notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] api-watchdog was down; tmux-watchdog restarted it (pid $!)"
}

# Keep the compaction watchdog alive too. Single-instance via pgrep so it never
# duplicates an instance brought up elsewhere. Same self-heal contract as
# ensure_api_watchdog. Opt-out: COMPACT_WATCHDOG_DISABLED=1.
ensure_compaction_watchdog() {
  [ "${COMPACT_WATCHDOG_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/compaction-watchdog.sh" ] || return 0
  # Per-TEAM_DIR flock liveness (atomic, stale-proof), replacing the old global
  # pgrep. A held lock = a live daemon for this team; skip. The daemon owns its
  # pidfile after winning the lock, so this launcher does not pre-write it.
  local lk="$TEAM_DIR/compaction-watchdog.lock"
  if command -v flock >/dev/null 2>&1; then
    if ! ( exec 201>"$lk" && flock -n 201 ) 2>/dev/null; then return 0; fi
  else
    pgrep -f 'bin/compaction-watchdog\.sh' >/dev/null 2>&1 && return 0
  fi
  COMPACT_SOCKET="$TEAM_TMUX" COMPACT_SESSION="$TEAM_SESSION" \
    COMPACT_LOG="$TEAM_DIR/compaction-watchdog.log" \
    nohup "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 9>&- &
  echo "$(iso) SELF-HEAL: compaction-watchdog was down; restarted (pid $!)" >> "$af"
  notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] compaction-watchdog was down; tmux-watchdog restarted it (pid $!)"
}

# Keep the efficiency observer alive. Same self-heal contract; the observer was
# previously in nobody's ensure set, so a crash left scaling advice silently off.
# Opt-out: OBSERVER_DISABLED=1.
ensure_observer() {
  [ "${OBSERVER_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/observer.sh" ] || return 0
  local pidf="$TEAM_DIR/observer.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
         && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'bin/observer\.sh'; then
      return 0
    fi
  fi
  nohup "$repo/bin/observer.sh" >"$TEAM_DIR/observer.log" 2>&1 9>&- &
  echo "$!" > "$pidf"
  echo "$(iso) SELF-HEAL: observer was down; restarted (pid $!)" >> "$af"
  notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] observer was down; tmux-watchdog restarted it (pid $!)"
}

# Keep the project intake poller alive -- the team's only inbound channel. It was
# unsupervised (hand-started, in no ensure set), so its death = silent intake
# loss. Resolve the script from project.conf (INTAKE_POLLER), pgrep on the path
# so a hand-started instance is never duplicated. Opt-out: INTAKE_POLLER_DISABLED=1.
ensure_intake_poller() {
  [ "${INTAKE_POLLER_DISABLED:-0}" = "1" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local poller="${INTAKE_POLLER:-}"
  if [ -z "$poller" ] && [ -f "$repo/project.conf" ]; then
    local WORKDIR="" INTAKE_POLLER=""
    # shellcheck disable=SC1091
    . "$repo/project.conf" 2>/dev/null || true
    [ -z "$poller" ] && poller="${INTAKE_POLLER:-}"
    [ -z "$poller" ] && [ -n "$WORKDIR" ] && poller="$WORKDIR/scripts/poller.py"
  fi
  [ -n "$poller" ] && [ -f "$poller" ] || return 0
  # Per-TEAM_DIR flock liveness (atomic; same lock the poller daemon holds). The
  # old pgrep was not atomic and could double-spawn the poller against a manual
  # start (double-ping). A held lock = running; skip.
  local lk="$TEAM_DIR/intake-poller.lock"
  if command -v flock >/dev/null 2>&1; then
    if ! ( exec 202>"$lk" && flock -n 202 ) 2>/dev/null; then return 0; fi
  else
    pgrep -f "$poller" >/dev/null 2>&1 && return 0
  fi
  nohup python3 "$poller" --peer orchestrator >"$TEAM_DIR/intake-poller.log" 2>&1 9>&- &
  echo "$!" > "$TEAM_DIR/intake-poller.pid"
  echo "$(iso) SELF-HEAL: intake-poller was down; restarted (pid $!)" >> "$af"
  notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] intake-poller was down; tmux-watchdog restarted it (pid $!)"
}

while true; do
  nowts=$(now)
  if command tmux -L "$TEAM_TMUX" has-session -t "$TEAM_SESSION" 2>/dev/null; then
    if [ "$prev_state" != "ok" ]; then
      since=$nowts
      echo "$(iso "$nowts") OK: tmux session $TEAM_SESSION is alive (was $prev_state)" >> "$af"
      # No push: recovery is not actionable (the operator who recovered it knows).
      # Only the TEAM CRASH below pushes. Logged only.
    fi
    prev_state=ok
    write_state ok "$nowts" "$since"
    # While the team is actually running, keep the supervisor daemons alive
    # (self-heal): api + compaction watchdogs, the observer, and the intake
    # poller (the team's only inbound channel).
    if active_has_entries; then
      ensure_api_watchdog; ensure_compaction_watchdog
      ensure_observer; ensure_intake_poller
    fi
    # Periodic forensic snapshot.
    if [ $((nowts - last_snap)) -ge "$snap_interval" ]; then
      snapshot
      last_snap=$nowts
    fi
  else
    if active_has_entries; then
      if [ "$prev_state" != "crashed" ]; then
        since=$nowts
        echo "$(iso "$nowts") CRASH: tmux session $TEAM_SESSION is GONE but active/ has live entries ($(wc -l < "$TEAM_DIR/active") roles); team is down" >> "$af"
        notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] TEAM CRASH: tmux session $TEAM_SESSION died. Roles lost. Bus + dashboard may still be running. Recover with: TEAM_RUN_ID=${TEAM_RUN_ID:-legacy} bin/start-orchestrator.sh goals/<goal>.md"
        # Drop a marker file so the operator-watching session notices.
        {
          echo "# tmux session crashed"
          echo
          echo "session: $TEAM_SESSION"
          echo "run_id:  ${TEAM_RUN_ID:-legacy}"
          echo "at:      $(iso "$nowts")"
          echo
          echo "Roles in \$TEAM_DIR/active when the crash was detected:"
          cat "$TEAM_DIR/active"
          echo
          echo "Last snapshots in \$TEAM_DIR/snapshots/."
          echo "Recover with:"
          echo "  TEAM_RUN_ID=${TEAM_RUN_ID:-legacy} bin/start-orchestrator.sh goals/<goal>.md"
        } > "$TEAM_DIR/CRASH-DETECTED.md.tmp.$$" \
          && mv -f "$TEAM_DIR/CRASH-DETECTED.md.tmp.$$" "$TEAM_DIR/CRASH-DETECTED.md"
      fi
      prev_state=crashed
      write_state crashed "$nowts" "$since"
    else
      # No active roles; the watchdog still reports state honestly but it's
      # not a crash. This is the normal post-stop-team state.
      prev_state=idle
      write_state idle "$nowts" "$since"
    fi
  fi
  sleep "$interval"
done

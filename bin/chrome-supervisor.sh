#!/usr/bin/env bash
# chrome-supervisor.sh: keep the chrome-devtools MCP healthy for a team. Long-lived
# daemon, one per team, started like the other watchdogs. It addresses the failure
# mode where a role wedges on a chrome-devtools MCP tool call that never returns.
#
# Why a role wedges: chrome-devtools-mcp serialises every tool call on a single
# in-process mutex and awaits the underlying Chrome DevTools operation with no
# timeout. If Chrome dies cleanly BETWEEN calls the MCP relaunches it on the next
# call and all is well. But if Chrome goes unresponsive DURING a call (the classic
# case on a small, low/zero-swap box under memory pressure: Chrome thrashes instead
# of dying, so the MCP still believes it is "connected" and the in-flight operation
# never rejects), the mutex is never released and every later tool call blocks
# forever. The role then sits on a tool call that never returns until a watchdog
# kills the whole session.
#
# This supervisor does two things, each scan:
#
#   A. REAP orphans. A chrome-devtools-mcp server left behind by a dead session is
#      reparented to init (PPID 1); its headless Chrome tree and /tmp profile leak
#      with it. That debris is the memory pressure that triggers the thrash-hang
#      above. Reaping it (PPID==1 only, so a live session is never touched) keeps
#      the box clear. This is the same logic as the ensure-chrome PreToolUse hook,
#      run on a timer so it happens even when no role is making a Chrome call.
#
#   B. FAST UN-WEDGE. When the api-watchdog has already classified a role as "stuck"
#      (its pane has not changed while busy for the stuck threshold - the signature
#      of a hung tool call), this kills THAT role's Chrome tree. Killing Chrome makes
#      the MCP's hung in-flight operation reject, which releases the mutex; the MCP
#      then relaunches Chrome on the role's next call. The role recovers in seconds,
#      with its context intact, instead of waiting out the api-watchdog's escalation
#      to a full retire+respawn. The two cooperate: this clears the cause (the dead
#      browser) while the api-watchdog clears the symptom (the stuck pane).
#
# Pure shell + tmux + jq + procfs. Never makes a Claude API call, so it cannot be
# rate-limited. Only ever signals processes reparented to init or descended from a
# role pane that is already known-stuck; a healthy session is never disturbed.
#
# Usage:
#   bin/chrome-supervisor.sh                 # blocking loop (launch-team starts it)
#   bin/chrome-supervisor.sh --interval 20   # seconds between scans
#   bin/chrome-supervisor.sh --once          # one scan, then exit (for testing)
#
# Env:
#   CHROME_SUPERVISOR_DISABLED=1   skip auto-start entirely (in launch-team/add-role)
#   CHROME_SUPERVISOR_INTERVAL=20  seconds between scans
#   CHROME_UNWEDGE_DISABLED=1      keep reaping, disable the stuck->kill-Chrome action
#   MEM_WARN_MB=800                log a warning when MemAvailable falls below this

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

interval="${CHROME_SUPERVISOR_INTERVAL:-20}"
unwedge_disabled="${CHROME_UNWEDGE_DISABLED:-0}"
mem_warn_mb="${MEM_WARN_MB:-800}"
once=0

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="$2"; shift 2;;
    --once)     once=1; shift;;
    *) echo "chrome-supervisor: unknown arg '$1'" >&2; shift;;
  esac
done

log() { echo "$(date -u +%FT%TZ) $*"; }

orphaned() { # pid -> true if reparented to init (owner provably gone)
  [ "$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')" = "1" ]
}

kill_tree() { # pid: TERM then KILL the whole process group
  local pid="$1" pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -n "$pgid" ]; then
    kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 0.3
    kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  else
    kill -KILL "$pid" 2>/dev/null
  fi
}

# Descendant pids of a root pid. Repeatedly expand the set until no new pids
# appear, so it handles arbitrary tree depth (claude -> npm exec -> node mcp ->
# chrome -> renderer/gpu children) regardless of intermediate reparenting.
descendant_set() {
  local root="$1"
  local -A inset=( [$root]=1 )
  local changed=1 pid ppid
  while [ "$changed" = 1 ]; do
    changed=0
    while read -r pid ppid; do
      [ -z "$pid" ] && continue
      if [ -n "${inset[$ppid]:-}" ] && [ -z "${inset[$pid]:-}" ]; then
        inset[$pid]=1; changed=1
      fi
    done < <(ps -eo pid=,ppid= 2>/dev/null)
  done
  # emit everything except the root itself
  for pid in "${!inset[@]}"; do [ "$pid" = "$root" ] || echo "$pid"; done
}

reap_orphans() {
  local pid
  # 1) orphaned chrome-devtools-mcp server processes
  for pid in $(pgrep -f 'chrome-devtools-mcp' 2>/dev/null || true); do
    if orphaned "$pid"; then log "reap: orphan chrome-devtools-mcp pid=$pid"; kill_tree "$pid"; fi
  done
  # 2) orphaned headless Chrome roots (carry --user-data-dir; --type= children keep
  #    the root as parent, so PPID==1 selects only orphaned roots)
  for pid in $(pgrep -f -- '--user-data-dir=[^ ]*puppeteer_dev_chrome_profile' 2>/dev/null || true); do
    if orphaned "$pid"; then log "reap: orphan chrome pid=$pid"; kill_tree "$pid"; fi
  done
  # 3) stale /tmp puppeteer profile dirs with no live Chrome
  local base d
  for base in /tmp "${TMPDIR:-/tmp}"; do
    for d in "$base"/puppeteer_dev_chrome_profile-*; do
      [ -d "$d" ] || continue
      pgrep -f -- "--user-data-dir=$d" >/dev/null 2>&1 || { rm -rf "$d" 2>/dev/null && log "reap: stale profile $d"; }
    done
  done
}

mem_check() {
  local avail_kb avail_mb
  avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  [ -n "$avail_kb" ] || return 0
  avail_mb=$(( avail_kb / 1024 ))
  if [ "$avail_mb" -lt "$mem_warn_mb" ]; then
    log "warn: MemAvailable ${avail_mb}MB < ${mem_warn_mb}MB; swap=$(awk '/^SwapFree:/{print int($2/1024)"MB free"}' /proc/meminfo 2>/dev/null)"
  fi
}

# Kill the Chrome tree(s) belonging to a role whose pane the api-watchdog marked
# stuck, so the MCP's hung op rejects and the mutex releases.
unwedge_stuck() {
  [ "$unwedge_disabled" = 1 ] && return 0
  tmux has-session -t "$TEAM_SESSION" 2>/dev/null || return 0
  local health_dir="$TEAM_DIR/health" hf role state pane_pid
  [ -d "$health_dir" ] || return 0
  for hf in "$health_dir"/*.json; do
    [ -f "$hf" ] || continue
    state="$(jq -r '.state // ""' "$hf" 2>/dev/null)"
    case "$state" in stuck|stuck-giveup) ;; *) continue;; esac
    role="$(basename "$hf" .json)"
    # the tmux entry "tmux" is the tmux-watchdog's own health, not a role pane
    [ "$role" = "tmux" ] && continue
    pane_pid="$(tmux list-windows -t "$TEAM_SESSION" -F '#{window_name} #{pane_pid}' 2>/dev/null \
                 | awk -v r="$role" '$1==r{print $2; exit}')"
    [ -n "$pane_pid" ] || continue
    # find Chrome roots (--user-data-dir, not --type= children) descended from the pane
    local descs root_pids p killed=0
    descs=" $(descendant_set "$pane_pid" | tr '\n' ' ') "
    root_pids="$(pgrep -f -- '--user-data-dir=[^ ]*puppeteer_dev_chrome_profile' 2>/dev/null || true)"
    for p in $root_pids; do
      case "$descs" in *" $p "*)
        log "unwedge: role=$role state=$state pane_pid=$pane_pid killing Chrome tree pid=$p (frees MCP mutex; MCP will relaunch on next call)"
        kill_tree "$p"; killed=1;;
      esac
    done
    [ "$killed" = 0 ] && log "unwedge: role=$role state=$state but no Chrome descended from pane_pid=$pane_pid (wedge is not Chrome-side)"
  done
}

scan() {
  reap_orphans
  mem_check
  unwedge_stuck
}

log "chrome-supervisor: starting team=$TEAM_SESSION run=${TEAM_RUN_ID:-legacy} interval=${interval}s unwedge=$([ "$unwedge_disabled" = 1 ] && echo off || echo on)"
if [ "$once" = 1 ]; then scan; exit 0; fi
while :; do
  scan
  sleep "$interval"
done

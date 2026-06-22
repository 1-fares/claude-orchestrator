#!/usr/bin/env bash
# host-ram-watchdog.sh — guard the host against an OOM (OOM resilience).
#
# A host OOM (RAM driven to ~97% by a local large jest coverage run stacked on headless
# Chrome) can have the kernel OOM-killer kill worker panes and drop the agent — an OOM
# that kills the orchestrator stops the whole team, so this is goal-anchored. It watches
# host free RAM and, at a low-headroom band, raises an ntfy alert + writes a marker that
# the heavy-work gate (bin/gates/heavy-work-gate.sh) consults to refuse launching heavy
# work.
#
# Deliberately LIGHTWEIGHT: pure shell + /proc/meminfo, no jq/python/tmux in the hot
# path, so it still runs when RAM is already tight. It only alerts + marks; it never
# kills anything (cheap-and-correct).
#
# Bands are RAM-primary with swap as an amplifier — defined + rationale in
# bin/lib/host-ram.sh (host_ram_band), single-sourced with the heavy-work gate. The
# kill precursor was avail~1% WITH swap~95%; RAM pressure was the cause, swap its
# symptom, so swap escalates only when RAM is also under pressure (a pure swap-trip
# false-positives on a healthy host — swap~89% at RAM~42% is benign). The watchdog adds
# hysteresis (hold WARN until RAM < RESUME_PCT). It only alerts + marks; it never kills.
#
# Env: HOST_RAM_WATCHDOG_DISABLED=1 | HRW_WARN_PCT | HRW_FREEZE_PCT | HRW_RESUME_PCT |
#      HRW_SWAP_HI_PCT | HRW_SWAP_AMP_RAM_PCT (see lib) |
#      HRW_INTERVAL (default 30s — short, since RAM can spike fast) | HRW_LOG |
#      HRW_HEALTH_DIR | HRW_MARKER | NTFY_URL.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib/host-ram.sh
. "$repo/bin/lib/host-ram.sh"   # ram_used_pct, swap_used_pct + the band thresholds (single-sourced with the gate)
WARN_PCT="$HRW_WARN_PCT"; FREEZE_PCT="$HRW_FREEZE_PCT"; RESUME_PCT="$HRW_RESUME_PCT"
SWAP_HI_PCT="$HRW_SWAP_HI_PCT"; SWAP_AMP_RAM_PCT="$HRW_SWAP_AMP_RAM_PCT"
INTERVAL="${HRW_INTERVAL:-30}"
LOG="${HRW_LOG:-${TEAM_DIR:-.}/host-ram-watchdog.log}"
HEALTH_DIR="${HRW_HEALTH_DIR:-${TEAM_DIR:-.}/health}"
MARKER="${HRW_MARKER:-$HEALTH_DIR/host-ram-low.md}"

[ "${HOST_RAM_WATCHDOG_DISABLED:-0}" = "1" ] && { echo "host-ram-watchdog disabled"; exit 0; }

# HRW_TEST=1 sources this file for unit tests: skip the singleton lock, pidfile, traps,
# and main loop, exposing the pure functions (ram_used_pct, band_for) to the harness.
if [ "${HRW_TEST:-0}" != 1 ]; then
mkdir -p "$HEALTH_DIR" 2>/dev/null || true
# Per-team singleton via flock under TEAM_DIR (atomic, stale-proof). fd 203 (distinct
# from the other daemons').
_HRW_LOCK="${HRW_LOCK:-${TEAM_DIR:-.}/host-ram-watchdog.lock}"
if command -v flock >/dev/null 2>&1 && exec 203>"$_HRW_LOCK"; then
  if ! flock -n 203; then
    echo "host-ram-watchdog already running (lock $_HRW_LOCK held); exiting"; exit 0
  fi
fi
_HRW_PIDF="${HRW_PIDFILE:-${TEAM_DIR:-.}/host-ram-watchdog.pid}"
echo $$ > "$_HRW_PIDF" 2>/dev/null || true
# Reap the backgrounded sleep child on signal so the flock frees at once and a plain
# TERM exits immediately.
_hrw_cleanup() { rm -f "$_HRW_PIDF" 2>/dev/null; pkill -P $$ 2>/dev/null || true; }
trap _hrw_cleanup EXIT
trap 'exit 0' TERM INT
_hrw_sleep() { sleep "$1" 203>&- & wait "$!" 2>/dev/null; }
fi

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }
notify() { [ -z "${NTFY_URL:-}" ] && return 0; curl -sS -m 5 -d "$1" "$NTFY_URL" >/dev/null 2>&1 || true; }

# band_for <ram_used> <swap_used> <cur_band> -> FREEZE | WARN | "" (CLEAR). Delegates
# the raw verdict to host_ram_band (lib, RAM-primary + swap-amplifier), then layers
# hysteresis: when the raw verdict clears, hold the current band until RAM drops below
# RESUME_PCT (avoids flapping at the WARN edge).
band_for() {
  local r="$1" s="$2" cur="${3:-}" raw
  raw="$(host_ram_band "$r" "$s")"
  if [ -n "$raw" ]; then echo "$raw"
  elif [ -n "$cur" ] && [ "$r" -ge "$RESUME_PCT" ]; then echo "$cur"   # dead-band: hold
  else echo ""
  fi
}

write_marker() {  # <band> <used_pct> <avail_kb> <swap_pct>
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
  {
    echo "# Host-RAM LOW — band ${1} (RAM used ${2}%, swap ${4:-?}%)"
    echo
    echo "_$(date -u +%Y-%m-%dT%H:%M:%SZ)_ — host RAM used ${2}% (avail ${3} kB), swap ${4:-?}% used."
    echo "WARN (RAM>=${WARN_PCT}%, or RAM>=${SWAP_AMP_RAM_PCT}% with swap>=${SWAP_HI_PCT}%): heavy work"
    echo "(full test suites, ETL, builds) is REFUSED by bin/gates/heavy-work-gate.sh until recovery."
    echo "FREEZE (RAM>=${FREEZE_PCT}%): OOM imminent — stop launching now."
    echo "Cause class: a local large jest coverage run (multiple node procs, several GB) is the"
    echo "controllable lever; the kill precursor was MemAvailable ~1% + swap ~95%."
  } > "$MARKER.tmp.$$" 2>/dev/null && mv -f "$MARKER.tmp.$$" "$MARKER" 2>/dev/null || rm -f "$MARKER.tmp.$$" 2>/dev/null || true
}

if [ "${HRW_TEST:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

log "start: warn ram>=${WARN_PCT}% (or ram>=${SWAP_AMP_RAM_PCT}%+swap>=${SWAP_HI_PCT}%) freeze ram>=${FREEZE_PCT}% resume ram<${RESUME_PCT}% interval=${INTERVAL}s marker=${MARKER}"
cur_band=""
while :; do
  used="$(ram_used_pct < /proc/meminfo 2>/dev/null)"
  if [ -z "$used" ]; then log "could not read /proc/meminfo"; _hrw_sleep "$INTERVAL"; continue; fi
  swap="$(swap_used_pct < /proc/meminfo 2>/dev/null)"; swap="${swap:-0}"
  avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  new_band="$(band_for "$used" "$swap" "$cur_band")"
  if [ "$new_band" != "$cur_band" ]; then
    case "$new_band" in
      FREEZE) log "BAND -> FREEZE (ram ${used}% / swap ${swap}%)"; write_marker FREEZE "$used" "$avail" "$swap"
              notify "🔴 [host-ram/${TEAM_RUN_ID:-legacy}] FREEZE: host RAM ${used}% used / swap ${swap}% (avail ${avail}kB). OOM imminent — heavy work refused." ;;
      WARN)   log "BAND -> WARN (ram ${used}% / swap ${swap}%)"; write_marker WARN "$used" "$avail" "$swap"
              notify "🟠 [host-ram/${TEAM_RUN_ID:-legacy}] WARN: host RAM ${used}% used / swap ${swap}% (avail ${avail}kB). Heavy work (test suites/ETL/builds) refused until headroom recovers." ;;
      "")     log "BAND -> CLEAR (ram ${used}% / swap ${swap}%); headroom restored"
              rm -f "$MARKER" 2>/dev/null || true
              [ -n "$cur_band" ] && notify "🟢 [host-ram/${TEAM_RUN_ID:-legacy}] CLEAR: host RAM ${used}% / swap ${swap}%; heavy work allowed again." ;;
    esac
    cur_band="$new_band"
  else
    log "ram ${used}% / swap ${swap}% (avail ${avail}kB) band=${cur_band:-clear}"
  fi
  _hrw_sleep "$INTERVAL"
done

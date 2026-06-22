#!/usr/bin/env bash
# disk-tmp-watchdog.sh — guard the host against a disk / tmpfs-quota stall.
#
# A host can throw "Disk quota exceeded" on /tmp writes WHILE the root fs still has
# space: a /tmp tmpfs under a per-user quota fills with stale test scratch (headless-
# Chrome/puppeteer profiles, jest temp dirs, mongo-memory-server), which silently
# breaks shell output-capture mid-command. A RAM guard does not catch this. This is the
# disk/tmp resource watchdog: it watches / and /tmp usage and, at a band, raises an ntfy
# alert + writes a marker. A heavy-work gate, if the deployment runs one, can consult
# that marker to refuse launching the big /tmp scratch producers (full jest suites,
# headless Chrome, mongo-memory-server, ETL, builds).
#
# Deliberately LIGHTWEIGHT: pure shell + df, no jq/python/tmux in the hot path. It only
# alerts + marks; it never deletes anything (cheap-and-correct; cleanup stays a
# deliberate operator action — rm on /tmp dirs is often permission-gated anyway).
#
# Bands + thresholds are single-sourced in bin/lib/disk-tmp.sh (disk_tmp_band), shared
# with any heavy-work gate so alerting + blocking never drift. Adds hysteresis (hold the
# band until BOTH filesystems drop below their RESUME floor).
#
# Env: DISK_TMP_WATCHDOG_DISABLED=1 | DTW_*_PCT (see lib) | DTW_INTERVAL (default 120s —
#      disk fills slower than RAM) | DTW_LOG | DTW_HEALTH_DIR | DTW_MARKER | NTFY_URL.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib/disk-tmp.sh
. "$repo/bin/lib/disk-tmp.sh"   # fs_used_pct, disk_tmp_band + the band thresholds (single-sourced with the gate)
ROOT_RESUME="$DTW_ROOT_RESUME_PCT"; TMP_RESUME="$DTW_TMP_RESUME_PCT"
INTERVAL="${DTW_INTERVAL:-120}"
LOG="${DTW_LOG:-${TEAM_DIR:-.}/disk-tmp-watchdog.log}"
HEALTH_DIR="${DTW_HEALTH_DIR:-${TEAM_DIR:-.}/health}"
MARKER="${DTW_MARKER:-$HEALTH_DIR/host-disk-tmp-low.md}"

[ "${DISK_TMP_WATCHDOG_DISABLED:-0}" = "1" ] && { echo "disk-tmp-watchdog disabled"; exit 0; }

# DTW_TEST=1 sources this file for unit tests: skip the singleton lock, pidfile, traps,
# and main loop, exposing the pure functions (fs_used_pct, disk_tmp_band, band_for).
if [ "${DTW_TEST:-0}" != 1 ]; then
mkdir -p "$HEALTH_DIR" 2>/dev/null || true
# Per-team singleton via flock under TEAM_DIR. fd 204 (distinct from the other daemons').
_DTW_LOCK="${DTW_LOCK:-${TEAM_DIR:-.}/disk-tmp-watchdog.lock}"
if command -v flock >/dev/null 2>&1 && exec 204>"$_DTW_LOCK"; then
  if ! flock -n 204; then
    echo "disk-tmp-watchdog already running (lock $_DTW_LOCK held); exiting"; exit 0
  fi
fi
_DTW_PIDF="${DTW_PIDFILE:-${TEAM_DIR:-.}/disk-tmp-watchdog.pid}"
echo $$ > "$_DTW_PIDF" 2>/dev/null || true
_dtw_cleanup() { rm -f "$_DTW_PIDF" 2>/dev/null; pkill -P $$ 2>/dev/null || true; }
trap _dtw_cleanup EXIT
trap 'exit 0' TERM INT
_dtw_sleep() { sleep "$1" 204>&- & wait "$!" 2>/dev/null; }
fi

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }
notify() { [ -z "${NTFY_URL:-}" ] && return 0; curl -sS -m 5 -d "$1" "$NTFY_URL" >/dev/null 2>&1 || true; }

# band_for <root%> <tmp%> <cur_band> -> FREEZE | WARN | "" (CLEAR). Delegates the raw
# verdict to disk_tmp_band (lib), then layers hysteresis: when the raw verdict clears,
# hold the current band until BOTH filesystems drop below their RESUME floor.
band_for() {
  local r="$1" t="$2" cur="${3:-}" raw
  raw="$(disk_tmp_band "$r" "$t")"
  if [ -n "$raw" ]; then echo "$raw"
  elif [ -n "$cur" ] && { [ "$r" -ge "$ROOT_RESUME" ] || [ "$t" -ge "$TMP_RESUME" ]; }; then echo "$cur"  # dead-band: hold
  else echo ""
  fi
}

write_marker() {  # <band> <root%> <tmp%>
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
  {
    echo "# Host disk/tmp LOW — band ${1} (/ used ${2}%, /tmp used ${3}%)"
    echo
    echo "_$(date -u +%Y-%m-%dT%H:%M:%SZ)_ — / used ${2}%, /tmp used ${3}%."
    echo "WARN (/ >=${DTW_ROOT_WARN_PCT}% or /tmp >=${DTW_TMP_WARN_PCT}%): a heavy-work gate, if"
    echo "configured, refuses heavy work (full jest suites, headless-Chrome/puppeteer,"
    echo "mongo-memory-server, ETL, builds) until recovery — those are the big /tmp producers."
    echo "FREEZE (/ >=${DTW_ROOT_FREEZE_PCT}% or /tmp >=${DTW_TMP_FREEZE_PCT}%): writes near failing — stop now."
    echo "Reclaim: docker volume/image prune (unused only); clear stale /tmp scratch after"
    echo "confirming no live test holds it."
  } > "$MARKER.tmp.$$" 2>/dev/null && mv -f "$MARKER.tmp.$$" "$MARKER" 2>/dev/null || rm -f "$MARKER.tmp.$$" 2>/dev/null || true
}

if [ "${DTW_TEST:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

log "start: warn />=${DTW_ROOT_WARN_PCT}% or tmp>=${DTW_TMP_WARN_PCT}%; freeze />=${DTW_ROOT_FREEZE_PCT}% or tmp>=${DTW_TMP_FREEZE_PCT}%; interval=${INTERVAL}s marker=${MARKER}"
cur_band=""
while :; do
  root="$(fs_used_pct /)"; tmp="$(fs_used_pct /tmp)"
  if [ -z "$root" ] && [ -z "$tmp" ]; then log "could not read df for / or /tmp"; _dtw_sleep "$INTERVAL"; continue; fi
  root="${root:-0}"; tmp="${tmp:-0}"
  new_band="$(band_for "$root" "$tmp" "$cur_band")"
  if [ "$new_band" != "$cur_band" ]; then
    case "$new_band" in
      FREEZE) log "BAND -> FREEZE (/ ${root}% / tmp ${tmp}%)"; write_marker FREEZE "$root" "$tmp"
              notify "🔴 [disk-tmp/${TEAM_RUN_ID:-legacy}] FREEZE: / ${root}% used, /tmp ${tmp}% used. Writes near failing (EDQUOT class) — heavy work refused, stop launching now." ;;
      WARN)   log "BAND -> WARN (/ ${root}% / tmp ${tmp}%)"; write_marker WARN "$root" "$tmp"
              notify "🟠 [disk-tmp/${TEAM_RUN_ID:-legacy}] WARN: / ${root}% used, /tmp ${tmp}% used. Heavy work (test suites/puppeteer/mongo-mem/ETL/builds) refused until reclaimed (docker prune + stale /tmp clear)." ;;
      "")     log "BAND -> CLEAR (/ ${root}% / tmp ${tmp}%); headroom restored"
              rm -f "$MARKER" 2>/dev/null || true
              [ -n "$cur_band" ] && notify "🟢 [disk-tmp/${TEAM_RUN_ID:-legacy}] CLEAR: / ${root}% / /tmp ${tmp}%; heavy work allowed again." ;;
    esac
    cur_band="$new_band"
  else
    log "/ ${root}% / tmp ${tmp}% band=${cur_band:-clear}"
  fi
  # Opportunistic: keep the run logs bounded (their bloat feeds the very disk pressure
  # this daemon guards). Cheap stat-only scan; only acts on a log past its size cap.
  [ -x "$repo/bin/rotate-team-logs.sh" ] && "$repo/bin/rotate-team-logs.sh" >/dev/null 2>&1 || true
  _dtw_sleep "$INTERVAL"
done

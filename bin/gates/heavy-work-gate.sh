#!/usr/bin/env bash
# heavy-work-gate.sh — refuse to launch heavy work when host RAM or disk/tmp headroom
# is thin. OOM resilience: a local large jest coverage run (several GB of node) stacked
# on headless Chrome can drive a host OOM that kills role panes; and a /tmp tmpfs quota
# can fill with test scratch and break writes (EDQUOT) while the root fs still has space.
# This gate is what heavy-work launchers (full local test-suite runs, ETL containers,
# builds) consult so they DO NOT launch when the host is already near either band.
#
# It is self-sufficient and lightweight (no jq/python/tmux): it reads /proc/meminfo and
# df LIVE — so it protects even if the watchdog daemons are down — AND honors a
# watchdog's marker if present. Shares the bands with the watchdogs via
# bin/lib/host-ram.sh and bin/lib/disk-tmp.sh, so "blocks" and "alerts" use the same
# thresholds.
#
# Usage:
#   bin/gates/heavy-work-gate.sh [--label "<what>"]    # exit 0 = OK to run; nonzero = REFUSE
#   e.g. before a full local suite:  bin/gates/heavy-work-gate.sh --label "jest full suite" && npm test
# Exit: 0 OK; 1 REFUSE (WARN/FREEZE band); 2 usage/unreadable.
set -uo pipefail

LABEL="heavy work"
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:-heavy work}"; shift 2 ;;
    -h|--help) sed -n '1,24p' "$0"; exit 0 ;;
    *) echo "heavy-work-gate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=bin/lib/host-ram.sh
. "$repo/bin/lib/host-ram.sh"
# shellcheck source=bin/lib/disk-tmp.sh
. "$repo/bin/lib/disk-tmp.sh"   # fs_used_pct, disk_tmp_band — disk/tmp band, single-sourced with disk-tmp-watchdog

# --- RAM band (OOM guard) ---
[ -r /proc/meminfo ] || { echo "heavy-work-gate: cannot read /proc/meminfo; refusing $LABEL to be safe" >&2; exit 1; }
ram="$(ram_used_pct < /proc/meminfo)"; swap="$(swap_used_pct < /proc/meminfo)"
[ -n "$ram" ] || { echo "heavy-work-gate: could not parse RAM; refusing $LABEL to be safe" >&2; exit 1; }
band="$(host_ram_band "$ram" "$swap")"   # FREEZE | WARN | "" — single-sourced with the watchdog
[ -n "$band" ] || band="OK"
RAM_MARKER="${HRW_MARKER:-${TEAM_DIR:-.}/health/host-ram-low.md}"
if [ "$band" = "OK" ] && [ -f "$RAM_MARKER" ]; then band="WARN(marker)"; fi

# --- disk/tmp band (EDQUOT guard) ---
root_pct="$(fs_used_pct /)"; tmp_pct="$(fs_used_pct /tmp)"
dt_band="$(disk_tmp_band "${root_pct:-0}" "${tmp_pct:-0}")"   # FREEZE | WARN | "" — single-sourced with the watchdog
[ -n "$dt_band" ] || dt_band="OK"
DT_MARKER="${DTW_MARKER:-${TEAM_DIR:-.}/health/host-disk-tmp-low.md}"
if [ "$dt_band" = "OK" ] && [ -f "$DT_MARKER" ]; then dt_band="WARN(marker)"; fi

# --- decision: refuse if EITHER constraint trips ---
if [ "$band" != "OK" ]; then
  echo "heavy-work-gate: REFUSE ${LABEL} — host RAM ${ram}% used / swap ${swap}% (band ${band})." >&2
  echo "The host is near the OOM band (precursor: avail~1% + swap~95%). Run heavy work (full test" >&2
  echo "suites, ETL, builds) on CI, not the host; or wait for headroom (the host-ram-watchdog" >&2
  echo "clears its marker below the resume floor). Override only with explicit operator sign-off." >&2
  exit 1
fi
if [ "$dt_band" != "OK" ]; then
  echo "heavy-work-gate: REFUSE ${LABEL} — / ${root_pct:-?}% used, /tmp ${tmp_pct:-?}% used (band ${dt_band})." >&2
  echo "The host is near the disk/tmp band (a /tmp tmpfs quota filled by stale puppeteer/jest/mongo-mem" >&2
  echo "scratch breaks writes with EDQUOT while / still has space). Heavy work is the big /tmp-scratch" >&2
  echo "producer. Reclaim first (docker volume/image prune of UNUSED only; clear stale /tmp scratch" >&2
  echo "after confirming no live test holds it), or run on CI. Override only with operator sign-off." >&2
  exit 1
fi
echo "heavy-work-gate: OK — RAM ${ram}% used, swap ${swap}%; / ${root_pct:-?}% , /tmp ${tmp_pct:-?}% (${LABEL} may run)."
exit 0

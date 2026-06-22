#!/usr/bin/env bash
# host-ram.sh — shared /proc/meminfo parsers + OOM-guard band thresholds.
#
# Single-sourced by bin/host-ram-watchdog.sh (the alerting daemon) and
# bin/gates/heavy-work-gate.sh (the blocking gate) so the band the gate enforces can
# never drift from the band the watchdog alerts on.
#
# Rationale: a host OOM kill precursor is MemAvailable ~1% (RAM used ~99%) WITH swap
# ~95% used — RAM pressure is the cause, swap filling is its SYMPTOM. So the band is
# RAM-PRIMARY (gate on MemAvailable), with swap only as an AMPLIFIER: high swap
# escalates ONLY when RAM is also under pressure. A pure swap-OR-trip false-positives
# on a healthy host (Linux parks idle pages in swap, so a healthy host can sit at
# swap ~89% / RAM ~42% with plenty of MemAvailable) and would block all heavy work.
# Bands:
#   FREEZE: RAM used >= FREEZE_PCT (95 = avail <= 5%, hard danger).
#   WARN:   RAM used >= WARN_PCT   (85 = avail <= 15%)
#           OR (RAM used >= SWAP_AMP_RAM_PCT 70 AND swap used >= SWAP_HI_PCT 90).
#   CLEAR:  below both. All env-overridable; defaults set only if unset.
: "${HRW_WARN_PCT:=85}"          # RAM used% >= -> WARN  (avail <= 15%)
: "${HRW_FREEZE_PCT:=95}"        # RAM used% >= -> FREEZE (avail <= 5%)
: "${HRW_RESUME_PCT:=75}"        # RAM used% <  -> eligible to CLEAR (watchdog hysteresis floor)
: "${HRW_SWAP_HI_PCT:=90}"       # swap used% >= , WITH RAM pressure, escalates to WARN
: "${HRW_SWAP_AMP_RAM_PCT:=70}"  # RAM used% floor for swap to count (below this, swap is benign/idle)

# ram_used_pct: stdin = /proc/meminfo -> integer used% = ceil(100*(Total-Avail)/Total).
# Echoes empty if MemTotal/MemAvailable are unreadable.
ram_used_pct() {
  awk '
    /^MemTotal:/     {tot=$2}
    /^MemAvailable:/ {avail=$2}
    END { if (tot>0 && avail!="") printf "%d", (100*(tot-avail)+tot-1)/tot }
  '
}

# swap_used_pct: stdin = /proc/meminfo -> integer swap used%. No swap (SwapTotal 0) -> 0.
swap_used_pct() {
  awk '
    /^SwapTotal:/ {tot=$2}
    /^SwapFree:/  {free=$2}
    END { if (tot>0 && free!="") printf "%d", (100*(tot-free)+tot-1)/tot; else print 0 }
  '
}

# host_ram_band <ram_used%> <swap_used%> -> FREEZE | WARN | "" (clear). RAM-primary;
# swap amplifies only when RAM is also under pressure (see the band rationale above).
# No hysteresis here — that is the watchdog's layer; the gate uses this raw verdict.
host_ram_band() {
  local r="$1" s="${2:-0}"
  if   [ "$r" -ge "$HRW_FREEZE_PCT" ]; then echo FREEZE
  elif [ "$r" -ge "$HRW_WARN_PCT" ]; then echo WARN
  elif [ "$r" -ge "$HRW_SWAP_AMP_RAM_PCT" ] && [ "$s" -ge "$HRW_SWAP_HI_PCT" ]; then echo WARN
  else echo ""
  fi
}

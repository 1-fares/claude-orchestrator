#!/usr/bin/env bash
# disk-tmp.sh — shared df parsers + disk/tmp band thresholds.
#
# Single-sourced by bin/disk-tmp-watchdog.sh (the alerting daemon) and, if a
# deployment runs one, a heavy-work gate (the blocking side), so the band the gate
# enforces can never drift from the band the watchdog alerts on.
#
# Why this exists: a host can hit EDQUOT ("Disk quota exceeded") on /tmp writes WHILE
# the root filesystem still has plenty of free space. A per-user quota on a /tmp tmpfs
# fills with stale test scratch (headless-Chrome/puppeteer profiles, jest temp dirs,
# mongo-memory-server data) and silently breaks shell output-capture mid-command. A RAM
# guard does not see this. This adds the missing disk/tmp band.
#
# TWO independent signals (a trip on EITHER is a trip):
#   - / (root fs): a full root blocks all writes (evidence dirs, logs, builds).
#   - /tmp (often tmpfs, sometimes under a per-user quota): fills fast with test
#     scratch; when tmpfs it also feeds host swap. tmp is the more fragile of the two,
#     so its WARN band is lower.
# Bands:
#   FREEZE: root used >= ROOT_FREEZE (92)  OR  tmp used >= TMP_FREEZE (88).
#   WARN:   root used >= ROOT_WARN   (85)  OR  tmp used >= TMP_WARN   (75).
#   CLEAR:  below both. All env-overridable; defaults set only if unset.
: "${DTW_ROOT_WARN_PCT:=85}"     # / used% >= -> WARN
: "${DTW_ROOT_FREEZE_PCT:=92}"   # / used% >= -> FREEZE
: "${DTW_ROOT_RESUME_PCT:=80}"   # / used% <  -> eligible to CLEAR (watchdog hysteresis floor)
: "${DTW_TMP_WARN_PCT:=75}"      # /tmp used% >= -> WARN (tmp is the fragile one)
: "${DTW_TMP_FREEZE_PCT:=88}"    # /tmp used% >= -> FREEZE
: "${DTW_TMP_RESUME_PCT:=65}"    # /tmp used% <  -> eligible to CLEAR

# fs_used_pct <mountpoint> -> integer used% from df (POSIX -P), or empty if unreadable.
# Lightweight: df only, no jq/python, so it still runs when the host is tight.
fs_used_pct() {
  df -P "$1" 2>/dev/null | awk 'NR==2 { p=$5; gsub(/%/,"",p); print p }'
}

# disk_tmp_band <root_used%> <tmp_used%> -> FREEZE | WARN | "" (clear).
# A trip on EITHER filesystem trips the band (independent signals). Empty inputs are
# treated as 0 (unreadable df -> do not false-trip; the watchdog logs the read failure).
disk_tmp_band() {
  local r="${1:-0}" t="${2:-0}"
  [ -n "$r" ] || r=0; [ -n "$t" ] || t=0
  if   [ "$r" -ge "$DTW_ROOT_FREEZE_PCT" ] || [ "$t" -ge "$DTW_TMP_FREEZE_PCT" ]; then echo FREEZE
  elif [ "$r" -ge "$DTW_ROOT_WARN_PCT" ]   || [ "$t" -ge "$DTW_TMP_WARN_PCT" ];   then echo WARN
  else echo ""
  fi
}

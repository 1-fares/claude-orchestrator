#!/usr/bin/env bash
# rotate-team-logs.sh — bound the size of the team run logs. The per-run daemon logs
# (watchdogs, observer, api-watchdog) have no built-in size cap and over a multi-day run
# can bloat the root fs and feed the very disk pressure the watchdogs guard against. It
# runs ONLY from bin/disk-tmp-watchdog.sh, once per watchdog cycle; nothing else in the
# repository calls it, so DISK_TMP_WATCHDOG_DISABLED=1 also stops run-log rotation. A
# run without that watchdog can wire it into cron instead.
#
# Race-safe for append-only writers: the daemons all log with `>>` (O_APPEND), so when a
# log exceeds MAX we archive its recent tail to <log>.1 and TRUNCATE the live file in
# place (`: > log`). O_APPEND writers keep appending cleanly from the new end; no fd swap,
# no lost lines mid-write. One rotation generation (.1) is kept — enough for forensics,
# bounded total. Lightweight: stat + tail only.
#
# Env: RTL_MAX_BYTES (default 26214400 = 25 MB) | RTL_KEEP_BYTES (tail kept, default
#      5242880 = 5 MB) | RTL_GLOBS (override the log set).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX="${RTL_MAX_BYTES:-26214400}"
KEEP="${RTL_KEEP_BYTES:-5242880}"

# Default set: every *.log under the run dirs (.team/ legacy + .team-<run-id>/ per-run), at
# any depth and for any run id. find lists only the logs already over MAX: one fork per call,
# not one stat per log. The former glob list expanded before `shopt -s globstar`, so `**`
# matched one level only, and `.team-r*` missed run ids that do not start with r.
# shellcheck disable=SC2206
globs=( ${RTL_GLOBS:-} )
if [ "${#globs[@]}" -eq 0 ]; then
  mapfile -t globs < <(find "$repo"/.team "$repo"/.team-*/ -type f -name '*.log' -size +"${MAX}"c 2>/dev/null)
fi

rotated=0
for f in "${globs[@]}"; do
  [ -f "$f" ] || continue
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  [ "$sz" -gt "$MAX" ] 2>/dev/null || continue
  # archive the recent tail, then truncate in place (O_APPEND-safe)
  if tail -c "$KEEP" "$f" > "$f.1.tmp" 2>/dev/null; then
    mv -f "$f.1.tmp" "$f.1" 2>/dev/null || rm -f "$f.1.tmp" 2>/dev/null
    : > "$f" 2>/dev/null && rotated=$((rotated+1))
    printf '%s rotated %s (was %s bytes, kept last %s in .1)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$f" "$sz" "$KEEP" >> "$f" 2>/dev/null || true
  else
    rm -f "$f.1.tmp" 2>/dev/null || true
  fi
done
[ "$rotated" -gt 0 ] && echo "rotate-team-logs: rotated $rotated log(s) over ${MAX}B"
exit 0

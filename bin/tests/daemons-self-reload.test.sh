#!/usr/bin/env bash
# Every long-running daemon must self-reload (bin/lib/self-reload.sh): init at
# startup with the libs it sources, check once per loop iteration, original args
# captured before parsing. Static assertions, so a new daemon cannot regress it.
#
# 2026-09-02: an engine sync landed a CEILING-STUCK escalation in
# compaction-watchdog.sh; the running process, started 24 August, kept the old code
# for nine hours because only api-watchdog.sh reloaded itself. A fix that is on disk
# and not in the process is not a fix.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
for f in api-watchdog compaction-watchdog observer permission-mode-watchdog tmux-watchdog chrome-supervisor host-ram-watchdog disk-tmp-watchdog watchdog; do
  p="$repo/bin/$f.sh"
  [ -f "$p" ] || { printf '  FAIL %s: missing\n' "$f"; fail=1; continue; }
  miss=""
  grep -q '_SR_ORIG_ARGS=("$@")' "$p" || miss="$miss args"
  grep -q 'self_reload_init "$0"' "$p" || miss="$miss init"
  grep -q 'self_reload_check "$0"' "$p" || miss="$miss check"
  bash -n "$p" 2>/dev/null || miss="$miss syntax"
  # every sourced $repo lib must be in the tracked set (the init call may span
  # continuation lines, as api-watchdog's does)
  init_block="$(sed -n '/self_reload_init "\$0"/,/[^\\]$/p' "$p")"
  while read -r lib; do
    case "$lib" in */self-reload.sh) continue;; esac
    printf '%s' "$init_block" | grep -qF "$lib" || miss="$miss untracked:${lib##*/}"
  done < <(grep -oE '^\. "\$repo/[^"]+"' "$p" | sed -E 's/^\. "\$repo\///; s/"$//')
  if [ -z "$miss" ]; then printf '  ok   %s\n' "$f"; else printf '  FAIL %s:%s\n' "$f" "$miss"; fail=1; fi
done
[ "$fail" = 0 ] && echo "daemons-self-reload.test: PASS" || { echo "daemons-self-reload.test: FAIL"; exit 1; }

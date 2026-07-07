#!/usr/bin/env bash
# self-reload.sh: let a long-running bash watchdog RE-EXEC itself when its own source
# (or a lib it sources) changes on disk. A running bash loop does NOT pick up edits to
# its own file, so a fix committed to a live daemon stays dormant until someone manually
# restarts it — the root cause of the 2026-07-07 wedge (a new handler was written but
# the days-old daemon kept running the old code). Contract:
#
#   . "$repo/bin/lib/self-reload.sh"
#   self_reload_init "$0" <each-lib-this-script-sources...>   # once, at startup
#   ... in the main loop, each iteration:
#   self_reload_check "$0" "${ORIG_ARGS[@]}"                  # re-exec on a stable change
#
# Guards (all mandatory — a bad reload is worse than staleness):
#   1. bash -n gate: never exec into a script that fails a syntax check; log + keep the
#      old code running instead.
#   2. Debounce: a change must be STABLE across one check (one loop interval) before it
#      acts, so a half-written file mid-save never triggers a re-exec.
#   3. flock-safe: a caller's singleton flock fd (e.g. `exec 200>lock; flock -n 200`) is
#      NOT close-on-exec, so it survives the exec; the re-run's own `exec 200>lock`
#      reassignment closes the inherited fd (releasing its lock) and re-acquires cleanly.
#      Verified: re-exec keeps the singleton, no deadlock, no double-start.

# self_reload_init <script> [sourced-lib ...] — record the baseline hash of the tracked
# fileset (the script itself plus every lib it sources).
self_reload_init() {
  _SR_SCRIPT="$1"; shift
  _SR_FILES=("$_SR_SCRIPT" "$@")
  _SR_BASELINE="$(_sr_hash)"
  _SR_PENDING=""
}

# _sr_hash: combined sha256 of all tracked files' bytes (an unreadable file is skipped,
# so a transiently-missing lib does not look like a change on its own).
_sr_hash() {
  local f
  { for f in "${_SR_FILES[@]}"; do [ -r "$f" ] && cat -- "$f"; done; } \
    | sha256sum 2>/dev/null | awk '{print $1}'
}

# self_reload_check <script> [args...] — call once per loop. Re-exec <script> with the
# given args iff the tracked set changed, the change was stable since the previous check
# (debounce), and the new <script> passes `bash -n`. No-op otherwise (a change that
# reverts to baseline clears the pending state).
self_reload_check() {
  local script="$1"; shift
  local cur; cur="$(_sr_hash)"
  if [ "$cur" = "$_SR_BASELINE" ]; then _SR_PENDING=""; return 0; fi
  # A change is present. Debounce: act only once the SAME new hash has persisted since
  # the previous check, so a file being written right now is not exec'd mid-save.
  if [ "$cur" != "$_SR_PENDING" ]; then
    _SR_PENDING="$cur"; return 0
  fi
  # Stable change. Never re-exec into a syntactically broken script.
  if ! bash -n -- "$script" 2>/dev/null; then
    _sr_log "self-reload: new $script fails bash -n; staying on old code"
    _SR_BASELINE="$cur"   # accept the hash so we do not re-log every loop; re-fires on the next DISTINCT change
    _SR_PENDING=""
    return 0
  fi
  _sr_log "self-reload: tracked source changed + valid; re-exec $script"
  # shellcheck disable=SC2093
  exec "$script" "$@"
  # exec should not return; if it somehow does, keep running on the old code.
  _sr_log "self-reload: exec $script FAILED; staying on old code"
  _SR_BASELINE="$cur"; _SR_PENDING=""
  return 0
}

# _sr_log: best-effort audit line. Uses the caller's $audit_dir when present (the team
# watchdogs define it), else a generic fallback; never fails the caller.
_sr_log() {
  local d="${audit_dir:-${TEAM_DIR:-/tmp}/audit/watchdog}"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)" "$1" \
    >> "$d/self-reload.log" 2>/dev/null || true
}

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
#   2. Debounce by file age: a change acts only once no tracked file has been written for
#      SELF_RELOAD_MIN_AGE seconds (default 10), so a half-written file mid-save never
#      triggers a re-exec. The age is the inode change time (ctime), not the mtime: a copy
#      that keeps the source's mtime (rsync -a, cp -a, tar) writes files that already look
#      old, and a future mtime would hold the reload back; ctime is set by the kernel on
#      every write and cannot be set from user space. A settled change re-execs on the
#      first check that sees it; the cost does not grow with the caller's loop interval (a
#      rule of "the same hash on two consecutive checks" made every reload wait one extra
#      interval, so a fix took up to 30 minutes on a 900 s loop). Where no change time can
#      be read, the two-check rule is the fallback.
#      SELF_RELOAD_MIN_AGE=0 acts at once (tests).
#   3. flock-safe: a caller's singleton flock fd (e.g. `exec 200>lock; flock -n 200`) is
#      NOT close-on-exec, so it survives the exec; the re-run's own `exec 200>lock`
#      reassignment closes the inherited fd (releasing its lock) and re-acquires cleanly.
#      Verified: re-exec keeps the singleton, no deadlock, no double-start.
#   4. A failed exec (file not executable, interpreter missing) does not end the daemon:
#      execfail is set around the exec, the failure is logged and the old code keeps
#      running.

# self_reload_init <script> [sourced-lib ...] — record the baseline hash of the tracked
# fileset (the script itself plus every lib it sources).
self_reload_init() {
  _SR_FILES=("$@")
  _SR_BASELINE="$(_sr_hash)"
  _SR_PENDING=""
}

# _sr_newest_ctime: the most recent inode change time (epoch) across the tracked set, or 0
# when none can be read (a missing file is skipped; a stat without -c, as on BSD, gives 0).
# One stat for the whole set; it runs only when the hash has changed.
_sr_newest_ctime() {
  local m newest=0
  while read -r m; do
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -gt "$newest" ] && newest="$m"
  done < <(stat -c '%Z' -- "${_SR_FILES[@]}" 2>/dev/null)
  printf '%s\n' "$newest"
}

# _sr_hash: combined sha256 of all tracked files' bytes (an unreadable file is skipped,
# so a transiently-missing lib does not look like a change on its own). One cat for the
# whole set, not one per file: this runs once per loop iteration in every daemon.
_sr_hash() {
  local h
  h="$(cat -- "${_SR_FILES[@]}" 2>/dev/null | sha256sum 2>/dev/null)"
  printf '%s\n' "${h%% *}"
}

# self_reload_check <script> [args...] — call once per loop. Re-exec <script> with the
# given args iff the tracked set changed, the change has settled (no tracked file written
# in the last SELF_RELOAD_MIN_AGE seconds), and the new <script> passes `bash -n`. No-op
# otherwise (a change that reverts to baseline clears the pending state).
self_reload_check() {
  local script="$1"; shift
  local cur; cur="$(_sr_hash)"
  if [ "$cur" = "$_SR_BASELINE" ]; then _SR_PENDING=""; return 0; fi
  # A change is present. Debounce: a file written in the last min_age seconds may still
  # be being written, so defer to the next check.
  local min_age="${SELF_RELOAD_MIN_AGE:-10}" newest
  case "$min_age" in ''|*[!0-9]*) min_age=10 ;; esac
  newest="$(_sr_newest_ctime)"
  if [ "$newest" -gt 0 ]; then
    if [ $(( $(date +%s) - newest )) -lt "$min_age" ]; then
      _SR_PENDING="$cur"; return 0
    fi
  elif [ "$cur" != "$_SR_PENDING" ]; then
    # No readable change time: the same new hash must be seen on two consecutive checks.
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
  # Without execfail a failed exec ends a non-interactive shell, and the daemon with it.
  local had_execfail=0
  shopt -q execfail && had_execfail=1
  shopt -s execfail
  # shellcheck disable=SC2093
  exec "$script" "$@"
  local rc=$?
  [ "$had_execfail" = 1 ] || shopt -u execfail
  _sr_log "self-reload: exec $script FAILED (rc=$rc); staying on old code"
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

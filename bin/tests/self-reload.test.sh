#!/usr/bin/env bash
# Unit test for bin/lib/self-reload.sh (2026-07-07).
#
# Proves the guarantees behind the self-reload fix for the stale-daemon wedge:
#   1. a VALID change to a watched script triggers a re-exec (the fix takes effect
#      without a manual restart), on the FIRST check once the change has settled;
#   2. a SYNTACTICALLY BROKEN change does NOT re-exec — the daemon stays on the old,
#      working code (a broken reload is worse than staleness);
#   3. a change younger than SELF_RELOAD_MIN_AGE is deferred (debounce by the files'
#      change time, ctime, which a copy that keeps the mtime cannot back-date);
#   4. a failed exec (target not executable) is logged and the daemon keeps running.
# Each case runs in its own directory under $T. Cases that write and check at once set
# SELF_RELOAD_MIN_AGE=0 so the fresh write acts on the first check.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# new_case <name>: a fresh directory C (script, markers, audit log) for one case.
new_case() { C="$T/$1"; mkdir -p "$C/audit"; }
result() { cat "$C/result" 2>/dev/null; }
alog() { cat "$C/audit/self-reload.log" 2>/dev/null; }

# A daemon-shaped throwaway script that watches ITSELF. On the first run it appends the
# given line to its own file (with a third argument, sets its mtime that many seconds in
# the past, a negative value in the future, as `cp -a` or `rsync -a` would; with a fourth,
# sleeps that many seconds), then runs <checks> self_reload_check passes. The re-exec'd
# instance detects the 'started' marker and records that a reload happened; if no exec
# occurs the first instance records 'stayed'.
make_wd() {  # make_wd <line> <checks> [age-seconds] [wait-seconds]
  local checks="" i
  for ((i = 0; i < $2; i++)); do checks+='self_reload_check "$0"'$'\n'; done
  cat > "$C/wd.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
audit_dir="$C/audit"
. "$repo/bin/lib/self-reload.sh"
self_reload_init "\$0"
if [ -f "$C/started" ]; then echo reloaded > "$C/result"; exit 0; fi
: > "$C/started"
printf '%s\n' "$1" >> "\$0"
${3:+touch -d "@\$(( \$(date +%s) - $3 ))" "\$0"}
${4:+sleep $4}
$checks
echo stayed > "$C/result"
exit 0
EOF
  chmod +x "$C/wd.sh"
}
run_wd() { timeout 15 bash "$C/wd.sh" >/dev/null 2>&1 || true; }

# Case 1: a VALID appended line -> re-exec on the FIRST check (one check only).
new_case valid
make_wd '# harmless valid comment appended by the test' 1
SELF_RELOAD_MIN_AGE=0 run_wd
[ "$(result)" = reloaded ] \
  && ok "valid source change triggers re-exec on the first check" \
  || bad "valid change did NOT re-exec on the first check (result='$(result)')"
grep -q 're-exec' <<<"$(alog)" \
  && ok "audit logs the re-exec" || bad "audit missing the re-exec line"

# Case 2: a BROKEN appended line -> bash -n fails -> NO exec -> result = stayed.
# (The broken text is appended AFTER the script's own `exit 0`, so the running instance
# never parses it; only self_reload_check's `bash -n` gate sees it and refuses to exec.)
new_case broken
make_wd 'if then fi )( unbalanced syntax' 2
SELF_RELOAD_MIN_AGE=0 run_wd
[ "$(result)" = stayed ] \
  && ok "broken source does NOT re-exec (stays on old code)" \
  || bad "broken source re-exec'd or crashed (result='$(result)')"
grep -q 'fails bash -n' <<<"$(alog)" \
  && ok "audit logs the bash -n rejection" || bad "audit missing the bash -n rejection"

# Case 3: no change -> no re-exec, no log churn.
new_case nochange
cat > "$C/wd.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
audit_dir="$C/audit"
. "$repo/bin/lib/self-reload.sh"
self_reload_init "\$0"
self_reload_check "\$0"
self_reload_check "\$0"
echo nochange > "$C/result"
EOF
SELF_RELOAD_MIN_AGE=0 timeout 15 bash "$C/wd.sh" >/dev/null 2>&1 || true
[ "$(result)" = nochange ] && ok "unchanged source does not re-exec" || bad "unchanged source re-exec'd unexpectedly"
[ -z "$(alog)" ] && ok "no audit churn when nothing changed" || bad "audit written despite no change"

# Case 4: a change younger than SELF_RELOAD_MIN_AGE is deferred, however many checks run.
new_case fresh
make_wd '# fresh change' 3
SELF_RELOAD_MIN_AGE=3600 run_wd
[ "$(result)" = stayed ] && ok "a fresh change is deferred (age below SELF_RELOAD_MIN_AGE)" \
  || bad "a fresh change re-exec'd before it settled (result='$(result)')"
[ -z "$(alog)" ] && ok "no re-exec logged for the deferred change" || bad "audit written for a deferred change"

# Case 5: a file written just now with an mtime an hour old (a copy that keeps the source's
# mtime) is still fresh: deferred. Debouncing by mtime re-exec'd here at once, possibly in
# the middle of a multi-file update.
new_case copied
make_wd '# copied with an old mtime' 1 3600
SELF_RELOAD_MIN_AGE=2 run_wd
[ "$(result)" = stayed ] && ok "a fresh write with a back-dated mtime is deferred" \
  || bad "a fresh write with a back-dated mtime re-exec'd before it settled (result='$(result)')"

# Case 6: once no tracked file has changed for SELF_RELOAD_MIN_AGE seconds, the FIRST check
# re-execs. The two-check rule this replaces needed a second check, one loop interval later.
new_case settled
make_wd '# settled change' 1 '' 3
SELF_RELOAD_MIN_AGE=2 run_wd
[ "$(result)" = reloaded ] && ok "a settled change re-execs on the first check" \
  || bad "a settled change did not re-exec on the first check (result='$(result)')"

# Case 7: an mtime in the future does not hold a settled change back.
new_case future
make_wd '# change with a future mtime' 1 -3600 3
SELF_RELOAD_MIN_AGE=2 run_wd
[ "$(result)" = reloaded ] && ok "a future mtime does not block a settled change" \
  || bad "a future mtime blocked the re-exec (result='$(result)')"

# Case 8: the exec itself fails (target not executable). The daemon must log it and keep
# running on the old code; without execfail the shell exits at the failed exec.
new_case execfail
printf '#!/usr/bin/env bash\necho ran > "%s/noexec-ran"\n' "$C" > "$C/noexec.sh"
chmod 644 "$C/noexec.sh"
cat > "$C/wd.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
audit_dir="$C/audit"
. "$repo/bin/lib/self-reload.sh"
self_reload_init "\$0"
printf '%s\n' '# change' >> "\$0"
self_reload_check "$C/noexec.sh"
if shopt -q execfail; then ef=on; else ef=off; fi
echo "survived execfail=\$ef" > "$C/result"
self_reload_check "$C/noexec.sh"
echo "survived twice execfail=\$ef" > "$C/result"
EOF
SELF_RELOAD_MIN_AGE=0 timeout 15 bash "$C/wd.sh" >/dev/null 2>&1 || true
[ "$(result)" = "survived twice execfail=off" ] \
  && ok "a failed exec leaves the daemon running, execfail restored" \
  || bad "a failed exec ended the daemon or left execfail on (result='$(result)')"
grep -q 'exec .*noexec.sh FAILED' <<<"$(alog)" \
  && ok "audit logs the failed exec" || bad "audit missing the exec FAILED line"
[ "$(grep -c 'FAILED' <<<"$(alog)")" = 1 ] \
  && ok "the failed exec is not retried on the next check (baseline accepted)" \
  || bad "exec FAILED logged $(grep -c 'FAILED' <<<"$(alog)") times (want 1)"
[ ! -e "$C/noexec-ran" ] && ok "the non-executable target never ran" || bad "the non-executable target ran"

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"

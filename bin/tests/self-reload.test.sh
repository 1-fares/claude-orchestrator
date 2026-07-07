#!/usr/bin/env bash
# Unit test for bin/lib/self-reload.sh (2026-07-07).
#
# Proves the two guarantees behind the self-reload fix for the stale-daemon wedge:
#   1. a VALID change to a watched script triggers a re-exec (the fix takes effect
#      without a manual restart);
#   2. a SYNTACTICALLY BROKEN change does NOT re-exec — the daemon stays on the old,
#      working code (a broken reload is worse than staleness).
# Debounce (a change must be seen stable across two consecutive checks) is exercised
# implicitly: the re-exec fires on the 2nd check, not the 1st.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
AD="$T/audit"; mkdir -p "$AD"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

# A daemon-shaped throwaway script that watches ITSELF. On the first run it appends the
# given line to its own file, then runs two self_reload_check passes (the 2nd is where a
# stable change acts). The re-exec'd instance detects the 'started' marker and records
# that a reload happened; if no exec occurs the first instance records 'stayed'.
make_wd() {
  cat > "$T/wd.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
audit_dir="$AD"
. "$repo/bin/lib/self-reload.sh"
self_reload_init "\$0"
if [ -f "$T/started" ]; then echo reloaded > "$T/result"; exit 0; fi
: > "$T/started"
printf '%s\n' "$1" >> "\$0"
self_reload_check "\$0"
self_reload_check "\$0"
echo stayed > "$T/result"
exit 0
EOF
  chmod +x "$T/wd.sh"
}

# Case 1: a VALID appended line -> stable change -> re-exec -> result = reloaded.
make_wd '# harmless valid comment appended by the test'
rm -f "$T/started" "$T/result"
timeout 15 bash "$T/wd.sh" >/dev/null 2>&1 || true
[ "$(cat "$T/result" 2>/dev/null)" = reloaded ] \
  && ok "valid source change triggers re-exec" \
  || bad "valid change did NOT re-exec (result='$(cat "$T/result" 2>/dev/null)')"
grep -q 're-exec' "$AD/self-reload.log" 2>/dev/null \
  && ok "audit logs the re-exec" || bad "audit missing the re-exec line"

# Case 2: a BROKEN appended line -> bash -n fails -> NO exec -> result = stayed.
# (The broken text is appended AFTER the script's own `exit 0`, so the running instance
# never parses it; only self_reload_check's `bash -n` gate sees it and refuses to exec.)
make_wd 'if then fi )( unbalanced syntax'
rm -f "$T/started" "$T/result"
timeout 15 bash "$T/wd.sh" >/dev/null 2>&1 || true
[ "$(cat "$T/result" 2>/dev/null)" = stayed ] \
  && ok "broken source does NOT re-exec (stays on old code)" \
  || bad "broken source re-exec'd or crashed (result='$(cat "$T/result" 2>/dev/null)')"
grep -q 'fails bash -n' "$AD/self-reload.log" 2>/dev/null \
  && ok "audit logs the bash -n rejection" || bad "audit missing the bash -n rejection"

# Case 3: no change -> no re-exec, no log churn.
make_wd '# unused'   # rewrites wd.sh but we do NOT mutate on this run
rm -f "$T/started" "$T/result" "$AD/self-reload.log"
cat > "$T/wd.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
audit_dir="$AD"
. "$repo/bin/lib/self-reload.sh"
self_reload_init "\$0"
self_reload_check "\$0"
self_reload_check "\$0"
echo nochange > "$T/result"
EOF
timeout 15 bash "$T/wd.sh" >/dev/null 2>&1 || true
[ "$(cat "$T/result" 2>/dev/null)" = nochange ] && ok "unchanged source does not re-exec" || bad "unchanged source re-exec'd unexpectedly"
[ ! -s "$AD/self-reload.log" ] && ok "no audit churn when nothing changed" || bad "audit written despite no change"

if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"

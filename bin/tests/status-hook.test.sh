#!/usr/bin/env bash
# bin/lib/status-hook.sh: the daemons' one way to tell people OUTSIDE the operator
# that the team has stopped working. Pure-bash test, no tmux, no team.
#
# What must hold: no hook configured = silent no-op; a configured hook is run with
# <event> <role> <detail>; the same (event, role) is not fired twice inside the
# dedupe window; a recovery event re-arms its counterpart; a non-executable hook
# is logged and skipped; a hung hook never blocks the caller (it runs in the
# background under a timeout). Every decision leaves a line in the log.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export TEAM_DIR="$TD"
mkdir -p "$TD/health" "$TD/reports"
# shellcheck disable=SC1091
. "$repo/bin/lib/status-hook.sh"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
log="$TD/reports/status-hook.log"
calls="$TD/calls"

# 1. No hook: nothing happens, nothing logged.
unset TEAM_STATUS_HOOK
status_hook usage-wall orchestrator "detail"
[ ! -f "$log" ] && ok "unset hook is a silent no-op" || bad "unset hook wrote a log"

# 2. Hook fires with the three arguments.
cat > "$TD/hook.sh" <<'H'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${CALLS}"
H
chmod +x "$TD/hook.sh"
export CALLS="$calls" TEAM_STATUS_HOOK="$TD/hook.sh" STATUS_HOOK_DEDUPE_SEC=1800 STATUS_HOOK_TIMEOUT_SEC=5
status_hook usage-wall orchestrator "limit hit"; wait
grep -q '^usage-wall|orchestrator|limit hit$' "$calls" 2>/dev/null && ok "hook received event, role, detail" || bad "hook not called with the three args"
grep -q 'FIRE usage-wall orchestrator' "$log" && ok "FIRE logged" || bad "FIRE not logged"

# 3. Same (event, role) inside the window: deduped, hook not re-run.
status_hook usage-wall orchestrator "limit hit again"; wait
[ "$(grep -c '^usage-wall|' "$calls")" = 1 ] && ok "second usage-wall deduped" || bad "usage-wall fired twice inside the window"
grep -q 'DEDUPE usage-wall orchestrator' "$log" && ok "DEDUPE logged" || bad "DEDUPE not logged"

# 4. A different role is independent; a recovery re-arms the counterpart.
status_hook usage-wall impl-be "limit hit"; wait
[ "$(grep -c '^usage-wall|impl-be|' "$calls")" = 1 ] && ok "dedupe is per role" || bad "dedupe leaked across roles"
status_hook usage-recovered orchestrator "back"; wait
status_hook usage-wall orchestrator "walled again"; wait
[ "$(grep -c '^usage-wall|orchestrator|' "$calls")" = 2 ] && ok "usage-recovered re-armed usage-wall" || bad "usage-wall did not fire after recovery"

# 5. Non-executable hook: skipped and said so.
chmod -x "$TD/hook.sh"
status_hook wedged infra "hung"; wait
grep -q 'SKIP wedged infra: hook not executable' "$log" && ok "non-executable hook is logged as SKIP" || bad "non-executable hook not reported"
chmod +x "$TD/hook.sh"

# 6. A hung hook does not block the caller and is logged as FAIL after the timeout.
cat > "$TD/hang.sh" <<'H'
#!/usr/bin/env bash
sleep 30
H
chmod +x "$TD/hang.sh"
export TEAM_STATUS_HOOK="$TD/hang.sh" STATUS_HOOK_TIMEOUT_SEC=1
t0=$(date +%s); status_hook compact-stuck orchestrator "x"; t1=$(date +%s)
[ $((t1 - t0)) -le 1 ] && ok "caller returned at once (hook backgrounded)" || bad "caller blocked on the hook"
wait
grep -q 'FAIL rc=124 compact-stuck orchestrator' "$log" && ok "hung hook logged as FAIL after timeout" || bad "hung hook not logged as FAIL: $(tail -2 "$log")"

[ "$fail" = 0 ] && echo "status-hook.test: PASS" || { echo "status-hook.test: FAIL"; exit 1; }

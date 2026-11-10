#!/usr/bin/env bash
# chrome-supervisor-unwedge.test.sh: bin/chrome-supervisor.sh
#   A. unwedge_stuck acts on stuck, stuck-giveup AND stuck-giveup-esc (the api-watchdog state of a role
#      still frozen after the escalation), and logs "no Chrome descended" once per stuck episode, not
#      on every 20 s scan;
#   B. a singleton lock: a second supervisor of the same run exits at once, and the lock fd is closed
#      for every child sleep.
# A sources the script through its CHROME_SUPERVISOR_TEST hook and replaces tmux, pgrep, descendant_set,
# kill_tree and log with recorders, so nothing is signalled. B runs `--once` with stand-in pgrep (no
# match, exit 0: nothing reaped, no profile dir removed) and tmux (no session) on PATH.
# Everything lives under one fixed scratch path, removed by literal path at the start and on exit, so
# do not run two copies of this test at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/isolate.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

rm -rf /tmp/orch-test-chrome-supervisor
mkdir /tmp/orch-test-chrome-supervisor || { echo "ABORT: cannot create the scratch dir"; exit 2; }
trap 'exec 7>&- 2>/dev/null; rm -rf /tmp/orch-test-chrome-supervisor' EXIT
S=/tmp/orch-test-chrome-supervisor
mkdir -p "$S/team/health" "$S/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/fakebin/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$S/fakebin/tmux"
chmod +x "$S/fakebin/pgrep" "$S/fakebin/tmux"

echo "== A. unwedge_stuck"
# Without the hook, sourcing would run the real scan loop in this shell: refuse instead.
grep -q 'CHROME_SUPERVISOR_TEST:-0}" = 1 ]; then return 0' "$repo/bin/chrome-supervisor.sh" \
  || { echo "ABORT: bin/chrome-supervisor.sh has no CHROME_SUPERVISOR_TEST hook; not sourcing it"; exit 2; }
(
  export TEAM_DIR="$S/team" TEAM_DIR_ALLOW_OVERRIDE=1 NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null
  export PATH="$S/fakebin:$PATH"
  # shellcheck disable=SC1091
  CHROME_SUPERVISOR_TEST=1 . "$repo/bin/chrome-supervisor.sh" 2>/dev/null || { echo "  FAIL sourcing the supervisor"; exit 1; }
  declare -F unwedge_stuck >/dev/null || { echo "  FAIL unwedge_stuck not defined"; exit 1; }
  pass=0; fail=0
  KILLED=(); LOGS=(); CHROME=""
  tmux() { case "$1" in has-session) return 0 ;; list-windows) echo "worker1 4242" ;; esac; }
  descendant_set() { echo 5000; echo 5001; }
  pgrep() { [ -n "$CHROME" ] && echo "$CHROME"; return 0; }
  kill_tree() { KILLED+=("$1"); }
  log() { LOGS+=("$*"); }
  state() { printf '{"state":"%s"}\n' "$1" > "$TEAM_DIR/health/worker1.json"; }
  nlog() { local n=0 l; for l in "${LOGS[@]}"; do [[ "$l" == *"no Chrome descended"* ]] && n=$((n+1)); done; echo "$n"; }

  for st in stuck stuck-giveup stuck-giveup-esc; do
    KILLED=(); CHROME=5000; state "$st"; unwedge_stuck
    [ "${KILLED[*]:-}" = 5000 ] && ok "state $st: the role's Chrome tree is killed" || no "state $st: kill" "killed=[${KILLED[*]:-}]"
  done
  KILLED=(); state active; unwedge_stuck
  [ "${#KILLED[@]}" -eq 0 ] && ok "state active: nothing killed" || no "active killed" "${KILLED[*]}"

  LOGS=(); CHROME=""; state stuck-giveup-esc
  unwedge_stuck; unwedge_stuck; unwedge_stuck
  [ "$(nlog)" = 1 ] && ok "no Chrome, three scans in one stuck episode: one line" || no "per-episode line" "$(nlog) lines"
  state stuck; unwedge_stuck
  [ "$(nlog)" = 1 ] && ok "a change between stuck states is the same episode" || no "same episode" "$(nlog) lines"
  state active; unwedge_stuck; state stuck; unwedge_stuck; unwedge_stuck
  [ "$(nlog)" = 2 ] && ok "after the role recovers, a new stuck episode logs once more" || no "new episode" "$(nlog) lines"
  CHROME=5000; unwedge_stuck; CHROME=""; unwedge_stuck
  [ "$(nlog)" = 3 ] && ok "after a Chrome kill, a later no-Chrome scan logs once more" || no "after kill" "$(nlog) lines"
  echo "$pass $fail" > "$S/a.result"
)
read -r ap af < "$S/a.result" 2>/dev/null || { ap=0; af=1; }
pass=$((pass + ap)); fail=$((fail + af))

echo "== B. singleton lock"
lock="$S/team/chrome-supervisor.lock"
runsup() {
  env PATH="$S/fakebin:$PATH" TEAM_DIR="$S/team" TEAM_DIR_ALLOW_OVERRIDE=1 NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null \
    timeout 60 bash "$repo/bin/chrome-supervisor.sh" --once >"$S/sup.out" 2>&1
}
: > "$lock"
exec 7>"$lock"; flock -n 7 || { echo "ABORT: cannot take the test lock"; exit 2; }
runsup; rc=$?
[ "$rc" -eq 0 ] && grep -q 'chrome-supervisor already running (lock .*chrome-supervisor.lock held); exiting' "$S/sup.out" \
  && ok "lock held: a second supervisor exits 0 at once" || no "lock held" "rc=$rc $(cat "$S/sup.out")"
! grep -q 'chrome-supervisor: starting' "$S/sup.out" && ok "lock held: no scan started" || no "scan started under a held lock"
exec 7>&-
runsup; rc=$?
[ "$rc" -eq 0 ] && grep -q 'chrome-supervisor: starting' "$S/sup.out" && ok "lock free: the supervisor starts and scans" \
  || no "lock free" "rc=$rc $(cat "$S/sup.out")"
n="$(grep -cE '^[[:space:]]*sleep "\$interval" 208>&-$|sleep 0\.3 208>&-' "$repo/bin/chrome-supervisor.sh")"
m="$(grep -cE '^[^#]*\bsleep ' "$repo/bin/chrome-supervisor.sh")"
[ "$n" -eq 2 ] && [ "$m" -eq 2 ] && ok "both child sleeps close the lock fd (208>&-)" || no "sleep fd" "closed=$n sleeps=$m"

echo
echo "chrome-supervisor-unwedge: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]

#!/usr/bin/env bash
# observer-call-skip.test.sh: bin/observer.sh --once against a fixture run dir with a stand-in `claude`
# that counts its calls.
#   - the model call is skipped while the decision inputs are unchanged, and forced on the 8th cycle;
#     a change to the inputs (the ledger) calls at once; a change to load or bus volume does not;
#   - a failed call writes a "MODEL CALL FAILED" entry with the reason and the call's stderr (never a
#     "## Recommendation"), its stderr reaches the observer log, and exactly one bus message goes to
#     the orchestrator at the third failure in a row; a good answer ends the streak;
#   - the audit evidence: daemon liveness through this run's pidfiles (another run's daemon is not
#     "alive"), the BUS figure counts only records of the last interval, the ledger list reads
#     DECISIONS*.md and skips the dreamer's *-archive.md.
# Hermetic: claude, tmux, gh, git and crontab are stand-ins on PATH; HOME is a fixture; the bus message
# goes to OBSERVER_ESCALATE_SINK. Everything lives under one fixed scratch path, removed by literal path
# at the start and on exit, so do not run two copies of this test at once.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/isolate.sh"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

daemon_pids=()
cleanup() {
  local p
  for p in "${daemon_pids[@]}"; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf /tmp/orch-test-observer-skip
}
rm -rf /tmp/orch-test-observer-skip
mkdir /tmp/orch-test-observer-skip || { echo "ABORT: cannot create the scratch dir"; exit 2; }
trap cleanup EXIT
S=/tmp/orch-test-observer-skip
TD="$S/team"; FB="$S/fakebin"
mkdir -p "$TD/observer" "$TD/models" "$FB" "$S/home/.claude/data/inter-session" "$S/d/bin" "$S/other"

# --- stand-ins -------------------------------------------------------------------------------
cat > "$FB/claude" <<EOF
#!/usr/bin/env bash
cat > "$S/stdin.last"
echo call >> "$S/calls"
case "\$(cat "$S/mode")" in
  ok)        printf '%s\n' 'VERDICT: team=hold models=keep host=ok flags=none' 'HEADLINE: skip-test answer' 'body' ;;
  fail)      echo 'boom-stderr: model unavailable' >&2; exit 1 ;;
  noverdict) echo 'Here is some prose without the contract.' ;;
esac
exit 0
EOF
cat > "$FB/tmux" <<'EOF'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
case "${1:-}" in has-session) exit 0 ;; list-windows) echo '0 orchestrator' ;; list-panes) echo 0 ;; esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/crontab"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/git"
chmod +x "$FB"/*
calls(){ [ -f "$S/calls" ] && wc -l < "$S/calls" | tr -d ' ' || echo 0; }

# --- fixture run dir ---------------------------------------------------------------------------
printf '# state\n## unit: a\nstatus: in-progress\n' > "$TD/state.md"
echo sonnet > "$TD/models/worker"
echo '# decisions' > "$TD/DECISIONS.md"
echo '# archived decisions' > "$TD/DECISIONS-archive.md"
iso_ago(){ date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }
buslog="$S/home/.claude/data/inter-session/messages.log"
{ printf '{"ts": "%s", "kind": "msg", "text": "old"}\n' "$(iso_ago 3600)"
  printf '{"ts": "%s", "kind": "msg", "text": "recent"}\n' "$(iso_ago 120)"
  printf '{"ts": "%s", "kind": "msg", "text": "recent"}\n' "$(iso_ago 10)"; } > "$buslog"
# Two stand-in daemons whose program is .../bin/<name>.sh: one of this run (TEAM_DIR=$TD), one of another.
printf '#!/usr/bin/env bash\nsleep 300 &\nwait\n' > "$S/d/bin/api-watchdog.sh"
cp "$S/d/bin/api-watchdog.sh" "$S/d/bin/tmux-watchdog.sh"
env -u TEAM_RUN_ID TEAM_DIR="$TD" bash "$S/d/bin/api-watchdog.sh" & daemon_pids+=("$!"); echo "$!" > "$TD/api-watchdog.pid"
env -u TEAM_RUN_ID TEAM_DIR="$S/other" bash "$S/d/bin/tmux-watchdog.sh" & daemon_pids+=("$!"); echo "$!" > "$TD/tmux-watchdog.pid"

run_obs() {
  env -u TEAM_RUN_ID PATH="$FB:$PATH" HOME="$S/home" TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 TEAM_TMUX="obsskip$$" \
    OBSERVER_GH_DISABLED=1 OBSERVER_ESCALATE_SINK="$S/esc" OBSERVER_INTERVAL=900 HV_BUSY=1000 HV_OVER=1000 \
    NOTIFY_SINK="$S/notify.sink" WATCH_ALERT_SINK="$S/watch.sink" \
    timeout 120 bash "$repo/bin/observer.sh" --once >>"$S/obs.out" 2>&1
}
esc_lines(){ [ -f "$S/esc" ] && wc -l < "$S/esc" | tr -d ' ' || echo 0; }

echo "== 1. first pass calls the model; the audit evidence is this run's"
echo ok > "$S/mode"
run_obs
[ "$(calls)" = 1 ] && ok "first pass: one model call" || no "first pass calls" "$(calls)"
grep -q '^## Recommendation' "$TD/observer/latest.md" && grep -q 'skip-test answer' "$TD/observer/latest.md" \
  && ok "latest.md holds the recommendation" || no "latest.md" "$(head -20 "$TD/observer/latest.md")"
grep -qE "^  api-watchdog: alive pid=${daemon_pids[0]}$" "$S/stdin.last" && ok "this run's daemon (pidfile + identity) is alive" \
  || no "own daemon liveness" "$(grep -A9 'DAEMON LIVENESS' "$S/stdin.last")"
grep -qE "^  tmux-watchdog: NOT RUNNING \(pid ${daemon_pids[1]}: alive but not this run's" "$S/stdin.last" \
  && ok "another run's daemon behind our pidfile is NOT RUNNING" || no "other run's daemon" "$(grep 'tmux-watchdog' "$S/stdin.last")"
grep -qE '^  observer: NOT RUNNING \(no observer.pid\)$' "$S/stdin.last" && ok "the observer does not find itself without a pidfile" \
  || no "observer self-match" "$(grep '  observer:' "$S/stdin.last")"
grep -q '^BUS: 2 messages logged in the last 900s' "$S/stdin.last" && ok "BUS counts the 2 records of the last interval, not the old one" \
  || no "BUS figure" "$(grep '^BUS' "$S/stdin.last")"
grep -q '^  DECISIONS.md: modified' "$S/stdin.last" && ! grep -q 'DECISIONS-archive.md' "$S/stdin.last" \
  && ok "ledger freshness reads DECISIONS.md and skips DECISIONS-archive.md" || no "decision files" "$(grep -A4 'LEDGER/DECISIONS' "$S/stdin.last")"

echo "== 2. unchanged inputs: 7 passes skipped, the 8th cycle forced"
cp "$TD/observer/latest.md" "$S/latest.before"
for i in 1 2 3 4 5 6 7; do run_obs; done
[ "$(calls)" = 1 ] && ok "7 unchanged passes made no model call" || no "skipped passes called" "$(calls)"
grep -q 'model call skipped (7 of 7 before a forced call)' "$S/obs.out" && ok "the skip is logged with its count" || no "skip log" "$(tail -3 "$S/obs.out")"
cmp -s "$S/latest.before" "$TD/observer/latest.md" && ok "a skipped pass leaves latest.md as the last answer" || no "latest.md changed on a skip"
run_obs
[ "$(calls)" = 2 ] && ok "the 8th cycle after a call is a forced call" || no "forced call" "$(calls)"

echo "== 3. load and bus volume are not decision inputs; the ledger is"
printf '{"ts": "%s", "kind": "msg", "text": "recent"}\n' "$(iso_ago 5)" >> "$buslog"
run_obs
[ "$(calls)" = 2 ] && ok "a new bus record alone does not call the model" || no "bus change called" "$(calls)"
echo 'status: review' >> "$TD/state.md"
run_obs
[ "$(calls)" = 3 ] && ok "a ledger change calls at once" || no "ledger change" "$(calls)"

echo "== 4. failed calls: reported as failures; one bus message at the third in a row"
echo fail > "$S/mode"; echo 'status: todo' >> "$TD/state.md"
run_obs
[ "$(calls)" = 4 ] && ok "changed inputs: the failing call is made" || no "fail call" "$(calls)"
grep -q '^## MODEL CALL FAILED: no recommendation this pass' "$TD/observer/latest.md" && ! grep -q '^## Recommendation' "$TD/observer/latest.md" \
  && ok "latest.md says MODEL CALL FAILED, no Recommendation heading" || no "failure entry" "$(sed -n '/^## /p' "$TD/observer/latest.md")"
grep -q '^Reason: rc=1; stderr: boom-stderr: model unavailable' "$TD/observer/latest.md" && ok "the reason names rc and the stderr line" \
  || no "reason" "$(grep '^Reason' "$TD/observer/latest.md")"
grep -q 'observer: model stderr: boom-stderr: model unavailable' "$S/obs.out" && ok "the call's stderr reaches the observer log" || no "stderr in log"
grep -q '^MODEL CALL FAILED: rc=1' "$TD/observer/history.md" && ok "history.md records the failure" || no "history entry"
[ "$(esc_lines)" = 0 ] && ok "no bus message after one failure" || no "early bus message" "$(cat "$S/esc")"
run_obs
[ "$(calls)" = 5 ] && ok "a failed call does not record the inputs: the next pass calls again" || no "retry after failure" "$(calls)"
[ "$(esc_lines)" = 0 ] && ok "no bus message after two failures" || no "bus after two" "$(cat "$S/esc")"
echo noverdict > "$S/mode"
run_obs
grep -q '^Reason: the answer has no VERDICT line' "$TD/observer/latest.md" && ok "an answer without a VERDICT line is a failure" \
  || no "noverdict reason" "$(grep '^Reason' "$TD/observer/latest.md")"
[ "$(esc_lines)" = 1 ] && grep -q 'status: observer: the model call has failed 3 passes in a row' "$S/esc" \
  && ok "third failure in a row: one bus message to the orchestrator" || no "third failure bus" "$(cat "$S/esc" 2>/dev/null)"
echo fail > "$S/mode"; run_obs
[ "$(esc_lines)" = 1 ] && ok "fourth failure: still one bus message" || no "fourth failure bus" "$(cat "$S/esc")"

echo "== 5. a good answer ends the streak"
echo ok > "$S/mode"; run_obs
grep -q '^## Recommendation' "$TD/observer/latest.md" && ok "recommendation back" || no "recommendation after recovery"
[ "$(cat "$TD/observer/.model-fail-streak")" = 0 ] && ok "failure streak reset to 0" || no "streak" "$(cat "$TD/observer/.model-fail-streak")"
echo fail > "$S/mode"; echo 'status: done' >> "$TD/state.md"
run_obs; run_obs; run_obs
[ "$(esc_lines)" = 2 ] && ok "a new run of three failures sends one new message" || no "second episode" "$(cat "$S/esc")"

[ ! -s "$S/notify.sink" ] && ok "nothing pushed to the phone" || no "notify sink" "$(cat "$S/notify.sink")"
echo
echo "observer-call-skip: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]

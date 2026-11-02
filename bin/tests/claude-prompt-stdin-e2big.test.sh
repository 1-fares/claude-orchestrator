#!/usr/bin/env bash
# claude-prompt-stdin-e2big.test.sh: the observer and the LLM judge hand the prompt to `claude -p` on
# STDIN. As one argv string it is capped at 128 KiB (MAX_ARG_STRLEN): "Argument list too long", rc=126.
#   (1) red control: the old argv form with a >128 KiB string fails with E2BIG (rc 126) in this shell;
#   (2) observer --once: the fake claude gets the prompt on stdin (a marker from the unit table), argv
#       carries only the flags, and the pass records the model answer;
#   (3) llm-judge.sh with a 200 KiB artifact reaches the fake on stdin and returns its verdict.
# Hermetic: mktemp TEAM_DIR, claude/tmux/gh/bus faked on PATH, NOTIFY_SINK and WATCH_ALERT_SINK set.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)" || { echo "  FAIL could not create scratch dir"; exit 1; }
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || { echo "  FAIL scratch dir empty/missing"; exit 1; }
trap 'rm -rf "${SCRATCH:?}"' EXIT
export NOTIFY_SINK="$SCRATCH/notify.sink" WATCH_ALERT_SINK="$SCRATCH/watch.sink"
fail=0; ok(){ printf '  ok   %s\n' "$1"; }; bad(){ printf '  FAIL %s\n' "$1"; fail=1; }

FAKEBIN="$SCRATCH/bin"; mkdir -p "$FAKEBIN"
STDIN_COPY="$SCRATCH/stdin.copy"; ARGV_LEN="$SCRATCH/argv.len"; PAYLOAD="$SCRATCH/payload"; FAKE_RC="$SCRATCH/fake.rc"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
cat > "$STDIN_COPY"
printf '%s' "\$*" | wc -c > "$ARGV_LEN"
cat "$PAYLOAD"
exit "\$(cat "$FAKE_RC" 2>/dev/null || echo 0)"
FAKE
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
while [ "${1:-}" = "-L" ] || [ "${1:-}" = "-f" ]; do shift 2; done
case "${1:-}" in has-session) exit 0 ;; list-windows) echo '0 orchestrator' ;; list-panes) echo 0 ;; esac
exit 0
FAKE
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/bus-send"
chmod +x "$FAKEBIN"/*

# (1) red control: the argv form the observer used until this fix.
BIG="$(head -c 204800 /dev/zero | tr '\0' 'x')"
rc=0; err="$(timeout 5 "$FAKEBIN/claude" -p "$BIG" 2>&1 </dev/null)" || rc=$?
if [ "$rc" = 126 ] && grep -q 'Argument list too long' <<<"$err"; then
  ok "(1) red control: a 200 KiB argv prompt fails with E2BIG (rc 126)"
else bad "(1) red control did not reproduce E2BIG (rc=$rc: $(printf '%s' "$err" | head -c 120))"; fi

# (2) observer --once: the prompt goes on stdin.
TD="$SCRATCH/.teamtest"; mkdir -p "$TD/observer"
{ echo '| Unit | Description | Owner | Due | Status |'; echo '|---|---|---|---|---|'
  desc="$(head -c 240 /dev/zero | tr '\0' 'd')"
  for i in $(seq -w 1 10); do echo "| BIGPAD-$i | $desc | worker | 2099-01-01 | OPEN |"; done; } > "$TD/state.md"
run_obs() {
  env -u TEAM_RUN_ID PATH="$FAKEBIN:$PATH" TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 TEAM_TMUX=obstest \
    OBSERVER_ESCALATE_SINK="$SCRATCH/esc" OBSERVER_BUS_SEND="$FAKEBIN/bus-send" \
    timeout 120 bash "$repo/bin/observer.sh" --once >"$SCRATCH/obs.out" 2>&1 || true
}
printf '%s\n' 'VERDICT: team=hold models=keep host=ok flags=none' 'HEADLINE: e2big stdin marker answer' 'ok' > "$PAYLOAD"
echo 0 > "$FAKE_RC"
run_obs
sz="$(wc -c < "$STDIN_COPY" 2>/dev/null || echo 0)"
if [ "$sz" -gt 1000 ] && grep -q 'BIGPAD-01' "$STDIN_COPY" && [ "$(cat "$ARGV_LEN" 2>/dev/null || echo 999999)" -lt 4096 ]; then
  ok "(2) observer prompt reached claude on stdin ($sz bytes, unit-table row present), argv carries only the flags ($(cat "$ARGV_LEN") bytes)"
else bad "(2) observer prompt not on stdin ($sz bytes on stdin, argv $(cat "$ARGV_LEN" 2>/dev/null) bytes)"; fi
if grep -q 'e2big stdin marker answer' "$TD/observer/latest.md" 2>/dev/null && ! grep -q 'ADVICE FAILED' "$TD/observer/latest.md"; then
  ok "(2) the pass recorded the model answer"
else bad "(2) the pass did not record the model answer: $(grep -m1 -E 'HEADLINE|ADVICE' "$TD/observer/latest.md" 2>/dev/null)"; fi

# (3) llm-judge.sh with a 200 KiB artifact.
head -c 204800 /dev/zero | tr '\0' 'a' > "$SCRATCH/artifact.txt"; echo 'JUDGE-TAIL-MARKER' >> "$SCRATCH/artifact.txt"
echo 'Pass if the artifact exists.' > "$SCRATCH/rubric.md"
echo '{"pass": true, "score": 5, "summary": "fine"}' > "$PAYLOAD"; echo 0 > "$FAKE_RC"; : > "$STDIN_COPY"
rc=0; env -u TEAM_RUN_ID PATH="$FAKEBIN:$PATH" TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 bash "$repo/bin/gates/llm-judge.sh" "$SCRATCH/artifact.txt" "$SCRATCH/rubric.md" --gate e2bigtest >"$SCRATCH/judge.out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -q 'JUDGE-TAIL-MARKER' "$STDIN_COPY" && [ "$(wc -c < "$STDIN_COPY")" -gt 204800 ]; then
  ok "(3) llm-judge: a 200 KiB artifact reaches claude on stdin and the verdict passes"
else bad "(3) llm-judge failed (rc=$rc, stdin $(wc -c < "$STDIN_COPY") bytes): $(tail -2 "$SCRATCH/judge.out")"; fi

[ ! -s "$NOTIFY_SINK" ] && ok "nothing pushed to the phone" || bad "a push reached NOTIFY_SINK"
if [ "$fail" -eq 0 ]; then echo "claude-prompt-stdin-e2big: ALL PASS"; else echo "claude-prompt-stdin-e2big: FAILED"; fi
exit "$fail"

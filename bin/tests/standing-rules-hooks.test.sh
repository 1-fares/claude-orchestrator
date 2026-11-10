#!/usr/bin/env bash
# standing-rules-hooks.test.sh: the deviation report of bin/hooks/hooks-common.sh (through
# bin/hooks/standing-rules.sh) and the daily cap of bin/hooks/fable-call-log.sh.
# Pure: hook payloads on stdin and a scratch TEAM_DIR at one literal path; no tmux, no claude.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S=/tmp/standing-rules-hooks-test
rm -rf /tmp/standing-rules-hooks-test
mkdir -p /tmp/standing-rules-hooks-test/td/reports /tmp/standing-rules-hooks-test/td/health
trap 'rm -rf /tmp/standing-rules-hooks-test' EXIT
# ORCH_HOME points at the scratch dir: no RULES-IN-FORCE.md and no CLAUDE.md there.
export TEAM_DIR="$S/td" ORCH_HOME="$S"
RULES="$repo/bin/hooks/standing-rules.sh"
FABLE="$repo/bin/hooks/fable-call-log.sh"
LOG="$S/td/reports/fable-calls.log"
today="$(date -u +%Y-%m-%d)"; yesterday="$(date -u -d yesterday +%Y-%m-%d)"; tomorrow="$(date -u -d tomorrow +%Y-%m-%d)"
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }
dev() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' | bash "$RULES" 2>&1; }
fable() { # fable <event>: an Agent call with model fable and a CLASS-1 prompt
  printf '{"hook_event_name":"%s","tool_name":"Agent","tool_input":{"model":"fable","prompt":"CLASS-1: why did it stall"}}' "$1" | bash "$FABLE" 2>&1
}
calls() { local i; for i in $(seq 1 "$1"); do printf '%sT08:00:00Z CLASS-1 subagent-fable call %s outcome=returned\n' "$today" "$i"; done; }
manual() { local i; for i in $(seq 1 "$1"); do printf '%sT08:00:01Z CLASS-1 call %s summary by hand returned\n' "$today" "$i"; done; }

echo "1. rule 9: ## unit: sections with an optional due: line"
cat > "$S/td/state.md" <<EOF
# Team state: test

## unit: late-one
owner: implementer
status: in-progress
due: $yesterday

## unit: closed-late
owner: tester
status: Done
due: $yesterday

## unit: no-due
owner: tester
status: todo

## unit: due-later
status: todo
due: $tomorrow

## unit: late-two
status: blocked-on:reviewer
due: ${yesterday}T12:00Z
EOF
out="$(dev)"
[[ "$out" == *"DEVIATION rule 9: overdue units in state.md: late-one late-two"* ]] && ok "overdue units named, closed / undated / future ones not" || bad "rule 9 output: $out"
printf '## unit: a\nstatus: todo\n\n## unit: b\nstatus: done\n' > "$S/td/state.md"
out="$(dev)"; [[ "$out" != *"rule 9"* ]] && ok "no due: lines, no rule 9 line" || bad "rule 9 fired without due lines: $out"

echo "2. rule 3: the mute file holds an epoch or a date string"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$S/td/health/maintenance-until"
out="$(dev)"; [[ "$out" == *"NOTE rule 3"* ]] && ok "future epoch mute reported" || bad "epoch mute missed: $out"
printf '%s\n' "$tomorrow 08:00 UTC" > "$S/td/health/maintenance-until"
out="$(dev)"; [[ "$out" == *"NOTE rule 3"* ]] && ok "future date-string mute reported" || bad "date mute missed: $out"
printf '%s\n' "$(( $(date +%s) - 60 ))" > "$S/td/health/maintenance-until"
out="$(dev)"; [[ "$out" != *"rule 3"* ]] && ok "past epoch mute silent" || bad "past mute reported: $out"
printf 'next tuesdai\n' > "$S/td/health/maintenance-until"
out="$(dev)"; [[ "$out" != *"rule 3"* ]] && ok "unparseable mute silent" || bad "garbage mute reported: $out"

echo "3. rule 5: one log line per Fable call"
{ calls 19; manual 19; } > "$LOG"
fable PreToolUse >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "19 calls plus 19 hand-written lines: the 20th call is allowed" || bad "cap counted hand-written lines (rc=$rc)"
out="$(dev)"; [[ "$out" != *"cap reached"* ]] && ok "deviation report agrees: cap not reached" || bad "deviation counted hand-written lines: $out"
fable PostToolUse >/dev/null
[ "$(grep -c 'subagent-fable' "$LOG")" = 20 ] && ok "PostToolUse appends one subagent-fable line" || bad "post line count: $(grep -c 'subagent-fable' "$LOG")"
out="$(fable PreToolUse)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"cap of 20"* ]] && ok "the 21st call is refused" || bad "cap not enforced at 20 (rc=$rc): $out"
out="$(dev)"; [[ "$out" == *"NOTE rule 5: Fable cap reached today (20 calls)"* ]] && ok "deviation report: cap reached at 20" || bad "cap note: $out"
printf '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"model":"fable","prompt":"no class here"}}' > "$S/noclass.json"
: > "$LOG"
bash "$FABLE" < "$S/noclass.json" >/dev/null 2>&1; [ $? = 2 ] && ok "a Fable prompt without CLASS-<N> is refused" || bad "unclassed prompt allowed"

[ "$fail" = 0 ] && echo "standing-rules-hooks.test: PASS" || { echo "standing-rules-hooks.test: FAIL"; exit 1; }

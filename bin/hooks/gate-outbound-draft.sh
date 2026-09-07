#!/usr/bin/env bash
# PreToolUse on the outbound message tools (matcher in settings): rule 5, class 4. A message longer than a status line
# (600 characters) needs a Fable draft pass logged as CLASS-4 within the last 30 minutes.
. "$(dirname "$0")/hooks-common.sh"
input="$(cat)"
len="$(printf '%s' "$input" | python3 -c 'import sys,json; d=json.load(sys.stdin); t=d.get("tool_input",{}); print(len(t.get("body_html") or t.get("body") or t.get("text") or t.get("message") or ""))' 2>/dev/null || echo 0)"
[ "${len:-0}" -gt 600 ] || exit 0
now=$(date +%s)
if [ -f "$_fable_log" ]; then
  while IFS= read -r line; do
    ts="${line%% *}"; t=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    [ $((now - t)) -le 1800 ] && exit 0
  done < <(grep -E "CLASS-4 " "$_fable_log" | grep -v SKIPPED | tail -5)
fi
echo "RULES IN FORCE 5, class 4: this message is $len characters, longer than a status line, and no CLASS-4 Fable draft is logged in the last 30 minutes. Run the draft through a Fable subagent (Agent tool, model fable, prompt starting with CLASS-4:), which logs itself, then send. Status lines under 600 characters are exempt." >&2
exit 2

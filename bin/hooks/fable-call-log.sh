#!/usr/bin/env bash
# PreToolUse + PostToolUse on the Agent tool: rule 5. Pre: refuse a Fable subagent past the
# daily cap. Post: append the log line automatically so logging cannot be forgotten.
. "$(dirname "$0")/hooks-common.sh"
input="$(cat)"
read -r ev model cls purpose <<<"$(printf '%s' "$input" | python3 -c '
import sys,json,re
d=json.load(sys.stdin); t=d.get("tool_input",{})
ev=d.get("hook_event_name",""); model=str(t.get("model","")).lower()
p=str(t.get("prompt",""))
m=re.match(r"\s*(CLASS-[1-4])", p); cls=m.group(1) if m else "CLASS-?"
purpose=re.sub(r"\s+"," ",p)[:90].replace("|"," ")
print(ev, model or "-", cls, purpose)' 2>/dev/null)"
case "$model" in fable|claude-fable*) ;; *) exit 0 ;; esac
mkdir -p "$(dirname "$_fable_log")" 2>/dev/null
if [ "$ev" = "PreToolUse" ]; then
  n=$(grep "^$_today" "$_fable_log" 2>/dev/null | grep -E "CLASS-[1-4?]" | grep -vc SKIPPED)
  if [ "${n:-0}" -ge 20 ]; then echo "RULES IN FORCE 5: the Fable cap of 20 calls a day is reached ($n). Queue this to tomorrow and log SKIPPED-CAP in reports/fable-calls.log." >&2; exit 2; fi
  [ "$cls" = "CLASS-?" ] && echo "RULES IN FORCE 5: start the Fable prompt with CLASS-1, CLASS-2, CLASS-3 or CLASS-4 so the call is logged with its class." >&2 && exit 2
  exit 0
fi
printf '%s %s subagent-fable %s outcome=returned\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cls" "$purpose" >> "$_fable_log"
exit 0

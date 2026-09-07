#!/usr/bin/env bash
# PreToolUse Read: rule 7. In the orchestrator's tree, a whole-file Read of more than 200
# lines is refused with the alternative. Roles in the product trees are not gated.
. "$(dirname "$0")/hooks-common.sh"
input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("cwd",""))' 2>/dev/null)"
[ "$cwd" = "$_repo" ] || exit 0
read -r fp off lim <<<"$(printf '%s' "$input" | python3 -c 'import sys,json; d=json.load(sys.stdin); t=d.get("tool_input",{}); print(t.get("file_path",""), t.get("offset","-"), t.get("limit","-"))' 2>/dev/null)"
[ -n "$fp" ] && [ -f "$fp" ] || exit 0
[ "$off" != "-" ] || [ "$lim" != "-" ] && exit 0
n=$(wc -l < "$fp" 2>/dev/null || echo 0)
if [ "$n" -gt 200 ]; then
  echo "RULES IN FORCE 7: $fp has $n lines. Read it with offset and limit, or grep for what you need; never a whole file over 200 lines (a 200k context filled twice in one day this way)." >&2
  exit 2
fi
exit 0

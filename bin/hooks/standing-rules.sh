#!/usr/bin/env bash
# SessionStart (startup|resume|clear|compact) and UserPromptSubmit hook.
# Why: a rule that lives only in the conversation is gone at the next compaction. This
# prints the rules card at every session start and after every compaction, and on each
# prompt prints only the measured deviations (silent when clean, so it costs nothing).
. "$(dirname "$0")/hooks-common.sh"
input="$(cat)"
case "$input" in
  *'"hook_event_name":"SessionStart"'*|*'"hook_event_name": "SessionStart"'*)
    for c in "$_repo/RULES-IN-FORCE.md" "$_repo"/*/RULES-IN-FORCE.md; do [ -f "$c" ] && { cat "$c"; break; }; done
    deviations ;;
  *) deviations ;;
esac
exit 0

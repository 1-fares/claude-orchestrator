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
    # A role's cwd is its working tree, so a compaction or /clear reloads THAT tree's
    # CLAUDE.md, never the engine CLAUDE.md where the bus loop is written down.
    # Say it here, where every session start lands.
    case "$input" in
      *'"source":"compact"'*|*'"source": "compact"'*|*'"source":"clear"'*|*'"source": "clear"'*)
        printf 'BUS (team roles): after this compaction or /clear, run python3 %s/bin/bus-inbox.py status <your-name>; reader=none means arm it again with Bash run_in_background (python3 %s/bin/bus-inbox.py wait <your-name> 7200), and start it first if the listener is dead. Never /is c, never a Monitor on client.py. Full text: %s/docs/BUS-INBOX.md\n' "$_repo" "$_repo" "$_repo" ;;
    esac
    deviations ;;
  *) deviations ;;
esac
exit 0

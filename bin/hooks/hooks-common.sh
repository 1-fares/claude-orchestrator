# shared by the standing-rules hooks; sourced, not executed
_repo="${ORCH_HOME:-$HOME/projects/payroll-ai-team}"
_td="${TEAM_DIR:-$(ls -d "$_repo"/.team-r* 2>/dev/null | head -1)}"
_today="$(date -u +%Y-%m-%d)"
_fable_log="$_td/reports/fable-calls.log"
deviations() {
  local real skipped over units pushes mute muted_until
  if [ -f "$_fable_log" ]; then
    real=$(grep "^$_today" "$_fable_log" | grep -E "CLASS-[1-4]" | grep -vc SKIPPED)
    skipped=$(grep "^$_today" "$_fable_log" | grep -E "CLASS-[1-4]" | grep -c SKIPPED)
    [ "$skipped" -gt 0 ] && [ "$real" -eq 0 ] && echo "DEVIATION rule 5: $skipped skipped Fable delegations today and 0 real ones."
    [ "$real" -ge 20 ] && echo "NOTE rule 5: Fable cap reached today ($real calls); queue further class work to tomorrow."
  fi
  if [ -f "$_td/state.md" ]; then
    over=$(awk -F'|' -v t="$_today" '/^\| *(C[1-9]|B1|A2|PR ?3727)/ { id=$2; due=$5; st=$6; gsub(/ /,"",id); gsub(/ /,"",due); if (st !~ /done/ && due != "" && due < t) printf "%s ", id }' "$_td/state.md")
    [ -n "$over" ] && echo "DEVIATION rule 9: overdue units in the state.md table: $over"
  fi
  if [ -f "$_td/reports/operator-pings.log" ]; then
    pushes=$(grep "^$_today" "$_td/reports/operator-pings.log" | grep -cE "\| SENT (page|action)")
    [ "$pushes" -ge 3 ] && echo "NOTE rule 1: $pushes pushes to the phone today; each must have been a page or action a human had to act on."
  fi
  mute="$_td/health/maintenance-until"
  if [ -f "$mute" ]; then muted_until="$(head -1 "$mute")"; [ "$(date -d "$muted_until" +%s 2>/dev/null || echo 0)" -gt "$(date +%s)" ] && echo "NOTE rule 3: maintenance mute active until $muted_until."; fi
  if [ -f "$_repo/CLAUDE.md" ] && [ "$(wc -c < "$_repo/CLAUDE.md")" -gt 32000 ]; then echo "DEVIATION rule 7: CLAUDE.md is $(( $(wc -c < "$_repo/CLAUDE.md") / 4000 ))k tokens; the trim (A2) is owed."; fi
}

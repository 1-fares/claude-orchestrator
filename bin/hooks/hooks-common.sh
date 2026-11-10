# shared by the standing-rules hooks; sourced, not executed
_repo="${ORCH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
_td="${TEAM_DIR:-$(ls -d "$_repo"/.team-r* 2>/dev/null | head -1)}"
_today="$(date -u +%Y-%m-%d)"
_fable_log="$_td/reports/fable-calls.log"
deviations() {
  local real skipped over units pushes mute muted_until mu_s
  if [ -f "$_fable_log" ]; then
    # A call is the line fable-call-log.sh writes (`subagent-fable`); a line written by hand
    # for the same call would count it twice.
    real=$(grep "^$_today" "$_fable_log" | grep 'subagent-fable' | grep -vc SKIPPED)
    skipped=$(grep "^$_today" "$_fable_log" | grep -E "CLASS-[1-4]" | grep -c SKIPPED)
    [ "$skipped" -gt 0 ] && [ "$real" -eq 0 ] && echo "DEVIATION rule 5: $skipped skipped Fable delegations today and 0 real ones."
    [ "$real" -ge 20 ] && echo "NOTE rule 5: Fable cap reached today ($real calls); queue further class work to tomorrow."
  fi
  if [ -f "$_td/state.md" ]; then
    # Ledger format of templates/state.md: one `## unit: <id>` section per unit, keys on their
    # own lines. A unit is overdue when it has `due: YYYY-MM-DD` before today (UTC) and its
    # status is not done. No `due:` line, no verdict.
    over=$(awk -v t="$_today" '
      function flush() { if (id != "" && due ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ && substr(due, 1, 10) < t && st != "done") printf "%s ", id; id = "" }
      /^## unit:/ { flush(); id = $0; sub(/^## unit:[ \t]*/, "", id); sub(/[ \t]+$/, "", id); due = ""; st = ""; next }
      /^#/        { flush(); next }
      id != "" && /^due:/    { due = $0; sub(/^due:[ \t]*/, "", due); next }
      id != "" && /^status:/ { st = tolower($0); sub(/^status:[ \t]*/, "", st); sub(/[ \t]+$/, "", st); next }
      END { flush() }' "$_td/state.md")
    [ -n "$over" ] && echo "DEVIATION rule 9: overdue units in state.md: $over"
  fi
  if [ -f "$_td/reports/operator-pings.log" ]; then
    pushes=$(grep "^$_today" "$_td/reports/operator-pings.log" | grep -cE "\| SENT (page|action)")
    [ "$pushes" -ge 3 ] && echo "NOTE rule 1: $pushes pushes to the phone today; each must have been a page or action a human had to act on."
  fi
  mute="$_td/health/maintenance-until"
  # First line: an epoch or a `date -d` string. notify_mute_epoch is the parse the notifier
  # itself uses (`date -d` alone rejects a bare epoch); the library is read only when a mute exists.
  if [ -f "$mute" ] && . "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh" 2>/dev/null; then
    muted_until="$(head -1 "$mute")"; mu_s="$(notify_mute_epoch "$muted_until")" || mu_s=0
    [ "$mu_s" -gt "$(date +%s)" ] && echo "NOTE rule 3: maintenance mute active until $muted_until."
  fi
  if [ -f "$_repo/CLAUDE.md" ] && [ "$(wc -c < "$_repo/CLAUDE.md")" -gt 32000 ]; then echo "DEVIATION rule 7: CLAUDE.md is $(( $(wc -c < "$_repo/CLAUDE.md") / 4000 ))k tokens, over the 8k a memory file may have at start; trim it."; fi
}

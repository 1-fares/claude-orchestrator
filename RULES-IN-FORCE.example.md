# RULES IN FORCE (template; the team owner dates and edits it). Re-shown at every session start, after every compaction, and on deviation.
1. Phone: `page` = a human must act now; `action` = today; all else is `info` in the daily digest. Nothing pages unless the call site says `page`. Every decision is a line in `reports/operator-pings.log`.
2. A self-healable condition never pages: the ensure first, then the orchestrator over the bus, then `action` after two failures. A finding exit is not a death.
3. Planned relaunch or reboot: `bin/notify-operator.sh --mute <until>` before, `--unmute` after.
4. Tests that can page set `NOTIFY_SINK` and `WATCH_ALERT_SINK`. Every daemon self-reloads every library it sources. Daemons reach the bus with `bin/bus-send.py`, never `send.py`.
5. Orchestrator stays on `claude-opus-4-6`. Root cause, design, routing/authority and outbound drafting go to a Fable subagent (Agent tool, `model: fable`, prompt starts with `CLASS-1..4:`), max 20 a day; every call or skip is a line in `reports/fable-calls.log`.
6. Observer runs on `claude-fable-5-1`, six audits a day; the orchestrator dispositions every AUDIT line.
7. Read with a line range or grep, never a whole file over 200 lines. Memory files at start under 8k tokens. Restart brief under 200 lines.
8. Nothing is parked on the operator: a decision is the product owner's, the team's, or obsolete; an entry parked on the operator states in one sentence why neither can decide it.
9. Open units live in the `state.md` unit table with owner and due date; the observer reports overdue ones; a compaction summary is not a record.
10. Unchanged and binding: shared environments A1-A6, the outbound allow-list, no autonomous preprod or production deploy.
Review date: <set one>. Full text: the standing directive file for this team.

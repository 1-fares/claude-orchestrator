#!/usr/bin/env bash
# status-hook.example.sh: the contract a project's TEAM_STATUS_HOOK must satisfy.
# Copy to bin/status-hook.sh (gitignored per clone) and make it executable, or
# point TEAM_STATUS_HOOK at your own script. Called as:
#
#   status-hook.sh <event> <role> <detail>
#
# with the event vocabulary documented in bin/lib/status-hook.sh. It must return
# quickly (it runs under STATUS_HOOK_TIMEOUT_SEC) and must never prompt.
#
# This example does two things any project can keep: append a line to a status
# file that a dashboard or another watcher can read, and, if STATUS_HOOK_WEBHOOK
# is set, POST a one-line JSON notice to it (a chat webhook, a status page).
# A real project replaces the POST with its own outbound (a Teams or Slack
# connector, an incident tool) and decides the audience per event.
set -uo pipefail
event="${1:-}"; role="${2:-}"; detail="${3:-}"
[ -n "$event" ] && [ -n "$role" ] || exit 2

status_file="${TEAM_DIR:-.}/reports/team-availability.log"
mkdir -p "$(dirname "$status_file")" 2>/dev/null || true
line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${event} ${role}: ${detail}"
printf '%s\n' "$line" >> "$status_file"

case "$event" in
  usage-wall)        human="The AI team has hit its usage limit and is paused until it resets." ;;
  usage-recovered)   human="The AI team is working again after the usage limit reset." ;;
  awaiting-operator) human="The AI team is blocked on a prompt only its operator can answer." ;;
  operator-answered) human="The AI team is unblocked and working again." ;;
  wedged)            human="Part of the AI team is stuck; its operator has been asked to intervene." ;;
  compact-stuck)     human="The AI team's coordinator is not responding to housekeeping; its operator has been alerted." ;;
  recovered)         human="The AI team has recovered and is working again." ;;
  *)                 human="AI team status: ${event}." ;;
esac

if [ -n "${STATUS_HOOK_WEBHOOK:-}" ]; then
  payload="$(printf '{"event":"%s","role":"%s","text":"%s (%s)"}' "$event" "$role" "$human" "$detail")"
  curl -sS -m 10 -X POST -H 'Content-Type: application/json' --data-raw "$payload" "$STATUS_HOOK_WEBHOOK" -o /dev/null || exit 1
fi
exit 0

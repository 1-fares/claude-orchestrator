#!/usr/bin/env bash
# notify-operator.sh TITLE MESSAGE [PRIORITY]
#
# Send an ntfy push to the operator (the human running the team) and record a
# machine-checkable success line. This is the ONE right way for the team to reach
# the operator on their phone. The harness PushNotification tool is NOT a
# substitute: it reaches only the terminal/desktop session, not mobile, so it must
# never be used to "ping the operator".
#
# Delivery target is $NTFY_URL (resolved by team-env.sh). ENGINE-GENERIC: no host,
# topic, or operator identity is hardcoded here -- point NTFY_URL anywhere.
#
# Behaviour:
#   - POST to $NTFY_URL with a Title and Priority header and MESSAGE as the body.
#   - On a non-200 response, retry ONCE.
#   - Append ONE line to $TEAM_DIR/reports/operator-pings.log:
#       <ISO-8601 UTC timestamp> | <title> | <http-status> | <message-id>
#   - Exit 0 only when a 200 was logged; non-zero otherwise, so a caller can
#     machine-check that the ping actually left the machine.
#
# Usage: bin/notify-operator.sh "Title" "Message body" [priority]
#   priority: an ntfy priority (min|low|default|high|urgent, or 1..5). Default: high.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"

title="${1:-}"
message="${2:-}"
priority="${3:-high}"

if [ -z "$title" ] || [ -z "$message" ]; then
  echo "usage: notify-operator.sh TITLE MESSAGE [PRIORITY]" >&2
  exit 2
fi
if [ -z "${NTFY_URL:-}" ]; then
  echo "notify-operator.sh: NTFY_URL is unset (team-env.sh); cannot reach the operator" >&2
  exit 3
fi

log_file="$TEAM_DIR/reports/operator-pings.log"
mkdir -p "$TEAM_DIR/reports" 2>/dev/null || true

# One POST attempt. Prints "<http_status>\t<message_id>" on stdout.
_send() {
  local out status body id
  out="$(curl -sS -m 10 \
           -H "Title: $title" \
           -H "Priority: $priority" \
           --data-raw "$message" \
           -w $'\n%{http_code}' \
           "$NTFY_URL" 2>/dev/null || printf '\n000')"
  status="${out##*$'\n'}"      # last line is the HTTP code emitted by -w
  body="${out%$'\n'*}"         # everything before it is the JSON response body
  if command -v jq >/dev/null 2>&1; then
    id="$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)"
  else
    id="$(printf '%s' "$body" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  printf '%s\t%s' "$status" "${id:-}"
}

res="$(_send)"
status="${res%%$'\t'*}"
msg_id="${res#*$'\t'}"

if [ "$status" != 200 ]; then
  res="$(_send)"                 # retry once
  status="${res%%$'\t'*}"
  msg_id="${res#*$'\t'}"
fi

printf '%s | %s | %s | %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$title" "$status" "${msg_id:-none}" >> "$log_file"

if [ "$status" = 200 ]; then
  echo "notify-operator.sh: delivered (HTTP 200, id ${msg_id:-unknown}); logged to $log_file"
  exit 0
fi
echo "notify-operator.sh: FAILED (HTTP $status); logged to $log_file" >&2
exit 1

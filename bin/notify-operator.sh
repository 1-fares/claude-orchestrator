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
# shellcheck disable=SC1091
. "$repo/bin/lib/notify.sh"

# Maintenance modes (cron and operators):
#   --digest            notify_flush, then one silent digest push of the info lines (08:00 Mon-Fri)
#   --flush             push actions queued out of hours (call at the start of working hours)
#   --mute <until>      write $TEAM_DIR/health/maintenance-until (epoch or a `date -d` string);
#                       actions and info are held, pages go out prefixed [maintenance]
#   --unmute            remove it
case "${1:-}" in
  --digest) notify_digest; exit 0 ;;
  --flush)  notify_flush;  exit 0 ;;
  --mute)   [ -n "${2:-}" ] || { echo "usage: notify-operator.sh --mute <until>" >&2; exit 2; }
            f="${NOTIFY_MUTE_FILE:-$TEAM_DIR/health/maintenance-until}"; mkdir -p "$(dirname "$f")"
            printf '%s\n' "$2" > "$f"; echo "muted until $2 ($f)"; exit 0 ;;
  --unmute) rm -f "${NOTIFY_MUTE_FILE:-$TEAM_DIR/health/maintenance-until}"; echo "unmuted"; exit 0 ;;
esac

title="${1:-}"
message="${2:-}"
priority="${3:-high}"

if [ -z "$title" ] || [ -z "$message" ]; then
  echo "usage: notify-operator.sh TITLE MESSAGE [page|action|info]  |  --digest | --flush | --mute <until> | --unmute" >&2
  exit 2
fi

# 2026-09-07: the policy lives in bin/lib/notify.sh. The third argument is a CLASS
# (page | action | info); the old ntfy priorities are accepted and mapped, and the
# old default of "high" maps to action, which is what "high" meant in practice.
# Exit 0 means the policy accepted the notice (SENT, QUEUED or DIGEST are all
# acceptance); non-zero means it could not be delivered or the class was bad.
# Only the literal word "page" pages. The old ntfy priorities map DOWN: urgent and
# high were what every caller sent, including the hourly stale-watch alarms, so they
# become action (one push per subject per 6 h, working hours, muted in maintenance).
case "$priority" in
  page)                        class=page ;;
  action|urgent|max|high|5|4)  class=action ;;
  *)                           class=info ;;
esac
log_file="${NOTIFY_LOG:-$TEAM_DIR/reports/operator-pings.log}"
notify_operator "$class" "$title" "$message"; rc=$?
last="$(tail -1 "$log_file" 2>/dev/null)"
echo "notify-operator.sh: $class :: ${last#* | }"
case "$last" in *"| SENT "*|*"| QUEUED "*|*"| DIGEST "*|*"| DEDUPE "*|*"| MUTED "*) exit 0 ;; esac
exit "${rc:-1}"

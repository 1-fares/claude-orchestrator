#!/usr/bin/env bash
# notify-operator.sh TITLE MESSAGE [CLASS]
#
# Send a notice to the operator (the human running the team) through the paging
# policy in bin/lib/notify.sh, and say in words whether the phone got it. This is
# the ONE right way for the team to reach the operator on their phone. The harness
# PushNotification tool is NOT a substitute: it reaches only the terminal/desktop
# session, not mobile, so it must never be used to "ping the operator".
#
# Delivery target is $NTFY_URL from the environment; unset = log only.
# ENGINE-GENERIC: no host, topic, or operator identity is hardcoded here.
#
# Behaviour:
#   - CLASS is page | action | info (docs/OPERATOR-PAGING.md); the old ntfy
#     priorities are accepted and mapped (below). Default: high, i.e. action.
#   - The policy logs ONE decision line to $TEAM_DIR/reports/operator-pings.log
#     (NOTIFY_LOG): <ISO-8601 UTC> | <DECISION> <class> ... <subject> :: <body>
#   - Exit 0: SENT, or accepted for later delivery or covered by an earlier push
#     (QUEUED, DIGEST, DEDUPE, MUTED). Exit 3: an action demoted to the digest.
#     Any other non-zero: NOT delivered (LOG-ONLY: no NTFY_URL or the push
#     failed; 2: bad class).
#
# Usage: bin/notify-operator.sh "Title" "Message body" [page|action|info]

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"
# shellcheck disable=SC1091
. "$repo/bin/lib/notify.sh"

# Maintenance modes (cron and operators):
#   --digest            notify_flush, then one silent digest push of the info lines (08:00 Mon-Fri)
#   --flush             push actions queued out of hours (call at the start of working hours)
#   --mute <until>      write $TEAM_DIR/health/maintenance-until; <until> is an epoch or a
#                       `date -d` string, resolved ONCE here and stored as an epoch (a relative
#                       string such as 'tomorrow' re-read later would never expire). A value
#                       that does not parse, or is not in the future, is refused (exit 2) and
#                       nothing is written. Actions are dropped (logged MUTED), info still
#                       goes to the digest, pages go out prefixed [maintenance]
#   --unmute            remove it
case "${1:-}" in
  --digest) notify_digest; exit 0 ;;
  --flush)  notify_flush;  exit 0 ;;
  --mute)   [ -n "${2:-}" ] || { echo "usage: notify-operator.sh --mute <until>" >&2; exit 2; }
            if ! until_s="$(notify_mute_epoch "$2")"; then
              echo "notify-operator.sh: --mute: cannot parse '$2'; NOT muted. Give an epoch (date +%s) or a date(1) string such as '2026-09-07 16:00' or '2026-09-07T16:00:00+02:00'." >&2
              exit 2
            fi
            if [ "$until_s" -le "$(_nt_now)" ]; then
              echo "notify-operator.sh: --mute: '$2' ($(date -u -d "@$until_s" +%Y-%m-%dT%H:%M:%SZ)) is not in the future; NOT muted." >&2
              exit 2
            fi
            f="${NOTIFY_MUTE_FILE:-$TEAM_DIR/health/maintenance-until}"; mkdir -p "$(dirname "$f")"
            printf '%s\n' "$until_s" > "$f"
            echo "muted until $(date -u -d "@$until_s" +%Y-%m-%dT%H:%M:%SZ) (epoch $until_s, from '$2'; $f)"; exit 0 ;;
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
# The decision of THIS call, from _nt_log. The log's last line was read here before: another
# sender can write between the call and the read, and with NOTIFY_SINK set and NOTIFY_LOG unset
# the policy logs to ${NOTIFY_SINK}.log, so a sent push read as "NOT DELIVERED".
_NT_LAST=""
notify_operator "$class" "$title" "$message"; rc=$?
last="$_NT_LAST"
# 2026-09-11: say in words whether the phone got it, and FAIL (exit 3) when it did not.
# The orchestrator reported "operator notified" after a DEMOTED decision it had not read;
# a false delivery claim is worse than no push. DEDUPE and MUTED stay exit 0: the
# policy accepted the notice and an earlier or later push covers it.
decision="${last#* | }"; decision="${decision%% *}"
case "$decision" in
  SENT)     echo "notify-operator.sh: $class :: DELIVERED to the phone :: ${last#* | }"; exit 0 ;;
  QUEUED)   echo "notify-operator.sh: $class :: ACCEPTED, NOT YET DELIVERED: queued for the next in-hours flush (outside the push window) :: ${last#* | }"; exit 0 ;;
  DIGEST)   echo "notify-operator.sh: info :: in the daily digest, no push :: ${last#* | }"; exit 0 ;;
  DEDUPE)   echo "notify-operator.sh: $class :: NOT PUSHED AGAIN: an earlier push for this subject is still within its cooldown :: ${last#* | }"; exit 0 ;;
  MUTED)    echo "notify-operator.sh: $class :: NOT PUSHED: maintenance mute is active :: ${last#* | }"; exit 0 ;;
  DEMOTED)  echo "notify-operator.sh: $class :: NOT DELIVERED TO THE PHONE. Demoted to the digest: sender [${NOTIFY_SOURCE:-unknown}] is not on the audible action list (NOTIFY_ACTION_SOURCES). Do not report the operator as notified. An item that needs the operator goes into the operator decisions file; the operator side relays it." >&2; exit 3 ;;
  # LOG-ONLY returns 0 from notify_operator; NOT DELIVERED must still fail the caller.
  *)        echo "notify-operator.sh: $class :: NOT DELIVERED: $last" >&2; [ "${rc:-0}" -ne 0 ] || rc=1; exit "$rc" ;;
esac

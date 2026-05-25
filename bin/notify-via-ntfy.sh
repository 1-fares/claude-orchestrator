#!/usr/bin/env bash
# notify-via-ntfy.sh: push an ntfy notification with one or more action buttons
# that call back into the notify-hook (for tap-to-approve from the phone).
#
# Pulls everything from env so the orchestrator and watchdog can call it as a
# single command without juggling state:
#
#   NTFY_URL          ntfy topic URL (required)
#   NOTIFY_HOOK_BASE  hook base URL (default http://127.0.0.1:8421)
#   TEAM_RUN_ID       run id to target (required for action buttons)
#
# Usage:
#   bin/notify-via-ntfy.sh --title "READY" --body "..." [--prio default]
#                          [--action approve] [--action pause]
#                          [--action 'priority:Use a custom label']
#
# Each --action is one of:
#   approve  pause  resume  stop  priority
# Optional ':label' overrides the button text. 'priority' must come with text,
# which the operator types in (ntfy supports prompt-on-tap, but we keep it
# simple: 'priority' here sends 'priority: phone tap' as a fixed message;
# extend by reading text input on the phone with the ntfy app's reply UI).

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${NTFY_URL:?NTFY_URL not set; export it in ~/.bashrc}"
: "${TEAM_RUN_ID:?TEAM_RUN_ID not set; cannot build action URLs}"
HOOK_BASE="${NOTIFY_HOOK_BASE:-http://127.0.0.1:8421}"

title=""
body=""
prio="default"
declare -a actions=()
while [ $# -gt 0 ]; do case "$1" in
  --title) title="$2"; shift 2 ;;
  --body) body="$2"; shift 2 ;;
  --prio) prio="$2"; shift 2 ;;
  --action) actions+=("$2"); shift 2 ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac done

# Build the Actions: header value. ntfy format documented at https://docs.ntfy.sh/publish/#action-buttons
build_actions_header() {
  local out="" first=1
  for spec in "${actions[@]}"; do
    local act="${spec%%:*}" label
    if [ "$spec" = "$act" ]; then label="$act"; else label="${spec#*:}"; fi
    local url
    url="$(NOTIFY_HOOK_BASE="$HOOK_BASE" "$repo/bin/sign-action-url.sh" "$act" "$TEAM_RUN_ID")"
    [ "$first" = 1 ] || out+="; "
    first=0
    out+="action=http, label=$label, url=$url, clear=true"
  done
  echo "$out"
}

args=(-sS -m 5 -o /dev/null -w '%{http_code}')
[ -n "$title" ] && args+=(-H "Title: $title")
[ -n "$prio" ]  && args+=(-H "Priority: $prio")
if [ "${#actions[@]}" -gt 0 ]; then
  hdr="$(build_actions_header)"
  args+=(-H "Actions: $hdr")
fi
args+=(-d "$body" "$NTFY_URL")

code="$(curl "${args[@]}")"
echo "ntfy push: HTTP $code  (actions: ${#actions[@]})"
[ "$code" = "200" ]

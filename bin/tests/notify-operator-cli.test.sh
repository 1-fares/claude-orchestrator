#!/usr/bin/env bash
# bin/notify-operator.sh: the exit code and the wording tell the caller whether the
# phone got the push. 2026-09-11: a DEMOTED action returned 0 and the orchestrator
# reported the operator as notified. Hermetic: sink, temp TEAM_DIR, no network.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/reports" "$TD/health"
export TEAM_DIR="$TD" TEAM_DIR_ALLOW_OVERRIDE=1 TEAM_RUN_ID=testrun NOTIFY_SINK="$TD/sink" NOTIFY_LOG="$TD/log" NOTIFY_STATE_DIR="$TD/st"
export NOTIFY_ACTION_SOURCES="c5-env-health c6-unanswered" NOTIFY_DAYS=1-7 NOTIFY_HOURS=0000-2400
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }
CLI="$repo/bin/notify-operator.sh"

out="$(NOTIFY_SOURCE= bash "$CLI" "CP3-SHRINK v3 needs GO" "please apply" action 2>&1)"; rc=$?
[ "$rc" = 3 ] && [[ "$out" == *"NOT DELIVERED TO THE PHONE"* ]] && ok "unlisted sender's action: exit 3, says not delivered" || bad "demoted action rc=$rc: $out"
out="$(NOTIFY_SOURCE=c5-env-health bash "$CLI" "dev down (HTTP 503)" "no run explains it" action 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"DELIVERED to the phone"* ]] && ok "listed sender's action: exit 0, says delivered" || bad "listed action rc=$rc: $out"
out="$(NOTIFY_SOURCE=c5-env-health bash "$CLI" "dev down (HTTP 503)" "again" action 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"NOT PUSHED AGAIN"* ]] && ok "dedupe inside the cooldown: exit 0, says not pushed again" || bad "dedupe rc=$rc: $out"
out="$(bash "$CLI" "lane restored" "reconciler" info 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"digest"* ]] && ok "info: exit 0, says digest" || bad "info rc=$rc: $out"
out="$(bash "$CLI" "production down" "502" page 2>&1)"; rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"DELIVERED to the phone"* ]] && ok "page: exit 0, delivered" || bad "page rc=$rc: $out"

# A push the service refuses (HTTP 500) is reported NOT DELIVERED with a non-zero exit. A stand-in curl
# answers; NTFY_URL is the local discard port and the stand-in never connects.
mkdir -p "$TD/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${FAKE_CURL_CALLS:-/dev/null}"' \
  'f=0; for a in "$@"; do case "$a" in -f|-fsS) f=1 ;; esac; done' \
  'printf %s "${FAKE_CURL_HTTP:-200}"; [ "$f" = 1 ] && [ "${FAKE_CURL_HTTP:-200}" -ge 400 ] && exit 22; exit 0' > "$TD/bin/curl"
chmod +x "$TD/bin/curl"
out="$(env -u NOTIFY_SINK PATH="$TD/bin:$PATH" NTFY_URL="http://127.0.0.1:9/cli-test" FAKE_CURL_HTTP=500 NOTIFY_SOURCE=c5-env-health \
  bash "$CLI" "preprod down" "HTTP 502" action 2>&1)"; rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"NOT DELIVERED"* ]] && [[ "$out" != *"DELIVERED to the phone"* ]] && ok "HTTP 500 from the push service: non-zero exit, says NOT DELIVERED" || bad "HTTP 500 rc=$rc: $out"

# --mute: a value the policy cannot resolve, or one already past, is refused and writes nothing; an
# epoch and a date string are accepted and stored as the resolved epoch. A relative string stored as
# given would be re-read later as a new instant ('tomorrow' never expires).
export NOTIFY_MUTE_FILE="$TD/health/maintenance-until"
out="$(bash "$CLI" --mute 'next tuesdai' 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$NOTIFY_MUTE_FILE" ] && [[ "$out" == *"NOT muted"* ]] && ok "--mute typo: exit 2, nothing written" || bad "--mute typo rc=$rc: $out"
out="$(bash "$CLI" --mute "$(( $(date +%s) - 60 ))" 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$NOTIFY_MUTE_FILE" ] && [[ "$out" == *"not in the future"* ]] && ok "--mute past epoch: exit 2, nothing written" || bad "--mute past rc=$rc: $out"
fut=$(( $(date +%s) + 3600 ))
out="$(bash "$CLI" --mute "$fut" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(head -1 "$NOTIFY_MUTE_FILE" 2>/dev/null)" = "$fut" ] && ok "--mute epoch: exit 0, stored" || bad "--mute epoch rc=$rc: $out"
( . "$repo/bin/lib/notify.sh"; notify_muted ) && ok "the policy reads the stored mute as active" || bad "stored mute not active"
bash "$CLI" --unmute >/dev/null 2>&1
t0=$(date +%s); out="$(bash "$CLI" --mute 'tomorrow' 2>&1)"; rc=$?; v="$(head -1 "$NOTIFY_MUTE_FILE" 2>/dev/null)"
case "$v" in ''|*[!0-9]*) v=0 ;; esac
[ "$rc" = 0 ] && [ "$v" -ge $((t0 + 86390)) ] && [ "$v" -le $((t0 + 86410)) ] && ok "--mute date string: stored as the epoch it resolved to once" || bad "--mute tomorrow rc=$rc stored='$(head -1 "$NOTIFY_MUTE_FILE" 2>/dev/null)': $out"
bash "$CLI" --unmute >/dev/null 2>&1; unset NOTIFY_MUTE_FILE

[ "$fail" = 0 ] && echo "notify-operator-cli.test: PASS" || { echo "notify-operator-cli.test: FAIL"; exit 1; }

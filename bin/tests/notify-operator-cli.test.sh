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

[ "$fail" = 0 ] && echo "notify-operator-cli.test: PASS" || { echo "notify-operator-cli.test: FAIL"; exit 1; }

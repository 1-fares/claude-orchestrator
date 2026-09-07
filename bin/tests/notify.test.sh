#!/usr/bin/env bash
# bin/lib/notify.sh: the operator-paging policy. Pure; no network (NOTIFY_SINK), no team.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export TEAM_DIR="$TD" TEAM_RUN_ID=testrun NOTIFY_SINK="$TD/sink" NOTIFY_LOG="$TD/log" NOTIFY_STATE_DIR="$TD/st"
. "$repo/bin/lib/notify.sh"
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }
posts() { [ -f "$TD/sink" ] && wc -l < "$TD/sink" || echo 0; }
last() { tail -1 "$TD/sink" 2>/dev/null; }
at() { date -d "TZ=\"Europe/Zurich\" $1" +%s; }   # local Zurich time -> epoch
reset() { rm -rf "$TD/sink" "$TD/log" "$TD/st" "$TD/health"; }

# 1. info never pushes; lands in the digest.
reset; NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator info "lane restored" "reconciler restored infra"
[ "$(posts)" = 0 ] && ok "info not pushed" || bad "info pushed"
grep -q "lane restored :: reconciler" "$TD/st/digest" && ok "info in digest" || bad "info missing from digest"
grep -q "DIGEST info lane restored" "$TD/log" && ok "info logged" || bad "info not logged"

# 2. action in hours pushes once at priority 4, dedupes for 6h, pushes again after.
reset
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "rotate the db password" "only you hold the SSM write"
[ "$(posts)" = 1 ] && [[ "$(last)" == "4|[testrun] rotate the db password|"* ]] && ok "action pushed at 4" || bad "action push wrong: $(last)"
NOTIFY_NOW=$(at "2026-09-07 12:00") notify_operator action "rotate the db password" "again"
[ "$(posts)" = 1 ] && ok "action deduped inside 6h" || bad "action reposted inside cooldown"
NOTIFY_NOW=$(at "2026-09-07 16:30") notify_operator action "rotate the db password" "again"
[ "$(posts)" = 2 ] && ok "action reposted after cooldown" || bad "action not reposted after 6h"

# 3. action out of hours is queued; flush at 07:00 Monday sends one combined push.
reset
NOTIFY_NOW=$(at "2026-09-05 22:10") notify_operator action "backup not pushed" "19 days"
NOTIFY_NOW=$(at "2026-09-06 09:00") notify_operator action "cert expires" "in 9 days"
[ "$(posts)" = 0 ] && ok "out-of-hours actions not pushed" || bad "pushed out of hours"
[ "$(wc -l < "$TD/st/queue")" = 2 ] && ok "two actions queued" || bad "queue wrong"
NOTIFY_NOW=$(at "2026-09-06 12:00") notify_flush
[ "$(posts)" = 0 ] && ok "Sunday flush sends nothing" || bad "flushed on Sunday"
NOTIFY_NOW=$(at "2026-09-07 07:00") notify_flush
[ "$(posts)" = 1 ] && [[ "$(last)" == "4|[testrun] 2 action(s) queued out of hours|"* ]] && ok "Monday 07:00 flush sends one combined push" || bad "flush wrong: $(last)"
[ ! -s "$TD/st/queue" ] && ok "queue emptied" || bad "queue not emptied"

# 4. maintenance mute: action dropped and logged, page still sent with a prefix.
reset; mkdir -p "$TD/health"; echo "$(at "2026-09-07 08:30")" > "$TD/health/maintenance-until"
NOTIFY_NOW=$(at "2026-09-07 07:35") notify_operator action "watch stale" "delivery-newfile"
[ "$(posts)" = 0 ] && grep -q "MUTED action watch stale" "$TD/log" && ok "action muted during maintenance" || bad "action not muted"
NOTIFY_NOW=$(at "2026-09-07 07:36") notify_operator page "production down" "app.the-fork.ch 502 x3"
[ "$(posts)" = 1 ] && [[ "$(last)" == "5|[maintenance] [testrun] production down|"* ]] && ok "page sent during mute with prefix" || bad "page wrong under mute: $(last)"
NOTIFY_NOW=$(at "2026-09-07 09:00") notify_operator action "watch stale" "delivery-newfile"
[ "$(posts)" = 2 ] && ok "action sent once mute expired" || bad "action still muted after expiry"

# 5. page repeats every 30 min until resolved; resolved pushes priority 3 and clears.
reset
NOTIFY_NOW=$(at "2026-09-07 03:00") notify_operator page "production down" "502"
NOTIFY_NOW=$(at "2026-09-07 03:10") notify_operator page "production down" "502"
[ "$(posts)" = 1 ] && ok "page deduped inside 30 min (and sent at night)" || bad "page repeat wrong ($(posts))"
NOTIFY_NOW=$(at "2026-09-07 03:31") notify_operator page "production down" "502"
[ "$(posts)" = 2 ] && ok "page re-paged after 30 min" || bad "page not repeated"
NOTIFY_NOW=$(at "2026-09-07 03:40") notify_resolved "production down" "answering again"
[ "$(posts)" = 3 ] && [[ "$(last)" == "3|[testrun] resolved: production down|answering again" ]] && ok "resolved pushed at 3" || bad "resolved wrong: $(last)"
[ ! -f "$TD/st/page.production_down" ] && ok "page state cleared" || bad "page state left"
NOTIFY_NOW=$(at "2026-09-07 03:41") notify_resolved "never paged"
[ "$(posts)" = 3 ] && ok "resolved without a page pushes nothing" || bad "spurious resolved push"

# 6. legacy shim: red = action, others = info; digits stripped from the subject.
reset; export NOTIFY_SOURCE=session-headroom
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_legacy "🔴 [session-headroom/r1] FREEZE: subscription burn 93% (session 5%)"
NOTIFY_NOW=$(at "2026-09-07 10:05") notify_legacy "🔴 [session-headroom/r1] FREEZE: subscription burn 94% (session 6%)"
[ "$(posts)" = 1 ] && ok "legacy red is action, deduped across changing numbers" || bad "legacy red wrong ($(posts))"
NOTIFY_NOW=$(at "2026-09-07 10:06") notify_legacy "🟠 [orchestrator/r1] lane 'infra' was dropped after a restart"
NOTIFY_NOW=$(at "2026-09-07 10:06") notify_legacy "🟢 [orchestrator/r1] reconciler restored dropped lane 'infra'"
[ "$(posts)" = 1 ] && [ "$(wc -l < "$TD/st/digest")" = 2 ] && ok "legacy orange and green are info" || bad "legacy non-red pushed"
unset NOTIFY_SOURCE

# 7. digest: one silent push, file rotated; empty digest sends nothing.
reset
NOTIFY_NOW=$(at "2026-09-07 07:00") notify_operator info "a" "1"
NOTIFY_NOW=$(at "2026-09-07 07:30") notify_operator info "b" "2"
NOTIFY_NOW=$(at "2026-09-07 08:00") notify_digest
[ "$(posts)" = 1 ] && [[ "$(last)" == "2|[testrun] daily digest: 2 info event(s)|"* ]] && ok "digest pushed once at 2" || bad "digest wrong: $(last)"
[ -f "$TD/st/digest.20260907" ] && [ ! -f "$TD/st/digest" ] && ok "digest rotated" || bad "digest not rotated"
NOTIFY_NOW=$(at "2026-09-08 08:00") notify_digest
[ "$(posts)" = 1 ] && ok "empty digest sends nothing" || bad "empty digest pushed"

# 8. no sink, no NTFY_URL: log-only, nothing crashes.
reset; unset NOTIFY_SINK; unset NTFY_URL
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator page "x" "y"; rc=$?
[ "$rc" = 0 ] && grep -q "LOG-ONLY page x" "$TD/log" && ok "log-only without a topic" || bad "log-only path broken"
export NOTIFY_SINK="$TD/sink"
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator bogus "x" "y"; rc=$?
[ "$rc" = 2 ] && grep -q "BAD-CLASS bogus" "$TD/log" && ok "bad class refused" || bad "bad class accepted"

[ "$fail" = 0 ] && echo "notify.test: PASS" || { echo "notify.test: FAIL"; exit 1; }

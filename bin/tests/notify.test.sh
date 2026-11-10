#!/usr/bin/env bash
# bin/lib/notify.sh: the operator-paging policy. Pure; no network (NOTIFY_SINK), no team.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export TEAM_DIR="$TD" TEAM_RUN_ID=testrun NOTIFY_SINK="$TD/sink" NOTIFY_LOG="$TD/log" NOTIFY_STATE_DIR="$TD/st"
# The sections assume every sender may push an action unless they set NOTIFY_ACTION_SOURCES
# themselves; a value inherited from the calling environment would mute some of them.
export NOTIFY_ACTION_SOURCES=""
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
NOTIFY_NOW=$(at "2026-09-07 07:35") notify_operator action "watch stale" "watch-a"
[ "$(posts)" = 0 ] && grep -q "MUTED action watch stale" "$TD/log" && ok "action muted during maintenance" || bad "action not muted"
NOTIFY_NOW=$(at "2026-09-07 07:36") notify_operator page "production down" "app.example.com 502 x3"
[ "$(posts)" = 1 ] && [[ "$(last)" == "5|[maintenance] [testrun] production down|"* ]] && ok "page sent during mute with prefix" || bad "page wrong under mute: $(last)"
NOTIFY_NOW=$(at "2026-09-07 09:00") notify_operator action "watch stale" "watch-a"
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

# 9. NOTIFY_ACTION_SOURCES: with an allowlist set, an action from any other sender lands
#    in the digest with a DEMOTED log line; listed senders push as before; pages are not
#    affected; unset, "" and "*" allow every sender.
reset; export NOTIFY_ACTION_SOURCES="env-health chat-unanswered"
export NOTIFY_SOURCE=backup-staleness
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "state backup stale" "19h"
[ "$(posts)" = 0 ] && grep -q "DEMOTED action->info \[backup-staleness\] state backup stale" "$TD/log" \
  && grep -q "state backup stale :: 19h" "$TD/st/digest" && ok "unlisted sender's action demoted to the digest" \
  || bad "unlisted sender's action not demoted (posts=$(posts))"
export NOTIFY_SOURCE=env-health
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "dev down (HTTP 503)" "no run explains it"
[ "$(posts)" = 1 ] && [[ "$(last)" == "4|[testrun] dev down (HTTP 503)|"* ]] && ok "listed sender's action pushed at 4" || bad "listed sender not pushed: $(last)"
export NOTIFY_SOURCE=api-watchdog
NOTIFY_NOW=$(at "2026-09-07 22:30") notify_operator page "ORCHESTRATOR wedged" "8m"
[ "$(posts)" = 2 ] && [[ "$(last)" == "5|"* ]] && ok "page unaffected by the allowlist" || bad "page affected: $(last)"
NOTIFY_ACTION_SOURCES="*" NOTIFY_SOURCE=anything NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "any" "b"
[ "$(posts)" = 3 ] && ok "'*' allows every sender" || bad "'*' did not allow (posts=$(posts))"
unset NOTIFY_ACTION_SOURCES
NOTIFY_SOURCE=anything NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "other" "b"
[ "$(posts)" = 4 ] && ok "unset allowlist allows every sender (default)" || bad "unset allowlist blocked (posts=$(posts))"
unset NOTIFY_SOURCE

# 10. a FAILED push must not open the dedupe window. With no sink and no topic _nt_push
#     returns non-zero; the stamp is written only on success, so the next attempt retries
#     instead of logging DEDUPE. Measured on a real outage: the first action push failed,
#     the stamp was already written, and five retries over the next hour all deduped while
#     the service stayed down. The page branch had the same order and is the worse case.
reset; unset NOTIFY_SINK; unset NTFY_URL
NOTIFY_NOW=$(at "2026-09-07 03:00") notify_operator page "production down" "502"
[ ! -f "$TD/st/page.production_down" ] && ok "failed page leaves no repeat stamp" || bad "failed page stamped the repeat window"
grep -q "LOG-ONLY page production down .*repeat window not started" "$TD/log" && ok "failed page says the window is open" || bad "failed page log line wrong"
NOTIFY_NOW=$(at "2026-09-07 03:05") notify_operator page "production down" "502"
[ "$(grep -c 'LOG-ONLY page production down' "$TD/log")" = 2 ] && ok "page retried 5 min after a failed push" || bad "page deduped after a failed push"
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "rotate the db password" "only you hold the SSM write"
[ ! -f "$TD/st/action.rotate_the_db_password" ] && ok "failed action leaves no cooldown stamp" || bad "failed action stamped the cooldown"
NOTIFY_NOW=$(at "2026-09-07 10:05") notify_operator action "rotate the db password" "again"
[ "$(grep -c 'LOG-ONLY action rotate the db password' "$TD/log")" = 2 ] && ok "action retried 5 min after a failed push" || bad "action deduped after a failed push"
export NOTIFY_SINK="$TD/sink"
NOTIFY_NOW=$(at "2026-09-07 10:10") notify_operator action "rotate the db password" "again"
[ "$(posts)" = 1 ] && [ -f "$TD/st/action.rotate_the_db_password" ] && ok "successful push stamps the cooldown" || bad "successful push did not stamp"

# 11. a queued out-of-hours action that resolves before the flush is dropped from the queue.
#     Without this the operator is told at 07:00 about a condition that cleared overnight.
reset
NOTIFY_NOW=$(at "2026-09-05 22:10") notify_operator action "subscription exhausted" "all roles stalled"
NOTIFY_NOW=$(at "2026-09-05 22:11") notify_operator action "cert expires" "in 9 days"
[ "$(wc -l < "$TD/st/queue")" = 2 ] && ok "two actions queued overnight" || bad "queue wrong before resolve"
NOTIFY_NOW=$(at "2026-09-05 23:40") notify_resolved "subscription exhausted" "reset at 23:40"
[ "$(wc -l < "$TD/st/queue")" = 1 ] && ok "resolved subject dropped from the queue" || bad "resolved subject still queued"
grep -q "UNQUEUED 1 queued action(s) subscription exhausted \[queue now 1\]" "$TD/log" && ok "unqueue logged with the new length" || bad "unqueue not logged"
NOTIFY_NOW=$(at "2026-09-07 07:00") notify_flush
[ "$(posts)" = 1 ] && [[ "$(last)" == "4|[testrun] 1 action(s) queued out of hours|cert expires:in 9 days" ]] && ok "flush carries only the unresolved action" || bad "flush wrong: $(last)"
NOTIFY_NOW=$(at "2026-09-07 07:05") notify_resolved "never queued"
grep -q "UNQUEUE-NOMATCH 0 queued action(s) never queued" "$TD/log" && ok "resolving an unqueued subject is logged, not an error" || bad "unqueue-nomatch not logged"

# 12. a sinked caller keeps its log and state beside the sink, never under the live TEAM_DIR.
#     A hand run or a test that inherits a live TEAM_DIR used to write fixture lines into the
#     operator's log and stamp the real dedupe files.
reset; unset NOTIFY_LOG; unset NOTIFY_STATE_DIR
export NOTIFY_SINK="$TD/fixture"
NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator info "fixture only" "must not reach the live tree"
[ -f "$TD/fixture.log" ] && grep -q "DIGEST info fixture only" "$TD/fixture.log" && ok "sinked log sits beside the sink" || bad "sinked log not beside the sink"
[ -f "$TD/fixture.state/digest" ] && ok "sinked state sits beside the sink" || bad "sinked state not beside the sink"
[ ! -e "$TD/reports/operator-pings.log" ] && ok "live operator log untouched by a sinked caller" || bad "sinked caller wrote the live log"
[ ! -e "$TD/health/notify" ] && ok "live state dir untouched by a sinked caller" || bad "sinked caller wrote the live state dir"
NOTIFY_SINK=/dev/null NOTIFY_NOW=$(at "2026-09-07 10:01") notify_operator info "devnull" "throwaway"; rc=$?
[ "$rc" = 0 ] && ok "/dev/null sink does not crash" || bad "/dev/null sink failed (rc=$rc)"
export NOTIFY_LOG="$TD/log" NOTIFY_STATE_DIR="$TD/st" NOTIFY_SINK="$TD/sink"

# A stand-in curl for the push path (sections 13 and 14). It answers HTTP $FAKE_CURL_HTTP and, like
# curl, exits 22 on a status >= 400 only when -f is given. It never opens a connection, and NTFY_URL
# points at the local discard port, so nothing leaves the machine. FAKE_CURL_HOOK runs in the
# background while the push "takes" FAKE_CURL_SLEEP seconds (its pid goes to FAKE_CURL_HOOK_PID).
mkdir -p "$TD/bin"
cat > "$TD/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_CALLS:-/dev/null}"
f=0; for a in "$@"; do case "$a" in -f|-fsS|-fs|-sf|-sSf) f=1 ;; esac; done
# The hook closes every inherited fd above 2 first: one of them is the caller's lock, which the hook
# would otherwise hold itself and then wait on (a real curl starts no such child).
if [ -n "${FAKE_CURL_HOOK:-}" ]; then
  ( for p in /proc/self/fd/*; do n="${p##*/}"; case "$n" in 0|1|2) ;; *) eval "exec $n>&-" 2>/dev/null ;; esac; done
    exec bash -c "$FAKE_CURL_HOOK" ) </dev/null >/dev/null 2>&1 &
  echo $! > "$FAKE_CURL_HOOK_PID"
fi
sleep "${FAKE_CURL_SLEEP:-0}"
code="${FAKE_CURL_HTTP:-200}"; printf '%s' "$code"
[ "$f" = 1 ] && [ "$code" -ge 400 ] && exit 22
exit 0
SH
chmod +x "$TD/bin/curl"
OLDPATH="$PATH"

# 13. a push the service refuses (HTTP 4xx or 5xx) is NOT delivered: curl runs with -f, so the policy
#     logs PUSH-FAIL and LOG-ONLY and opens no cooldown. Without -f curl exits 0 on an HTTP error and
#     the push counted as SENT.
reset; unset NOTIFY_SINK; export PATH="$TD/bin:$OLDPATH" NTFY_URL="http://127.0.0.1:9/notify-test" FAKE_CURL_CALLS="$TD/curl.calls"
FAKE_CURL_HTTP=500 NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator action "service down" "HTTP 503"
grep -q 'PUSH-FAIL curl rc=22 http=500' "$TD/log" && ok "HTTP 500 from the push service logged as PUSH-FAIL" || bad "no PUSH-FAIL for HTTP 500: $(cat "$TD/log")"
grep -q 'LOG-ONLY action service down' "$TD/log" && ! grep -q 'SENT action' "$TD/log" && ok "HTTP 500: LOG-ONLY, not SENT" || bad "HTTP 500 counted as delivered: $(cat "$TD/log")"
[ ! -f "$TD/st/action.service_down" ] && ok "HTTP 500 opens no cooldown" || bad "HTTP 500 stamped the cooldown"
grep -q -- '-fsS' "$TD/curl.calls" 2>/dev/null && ok "the push runs curl with -f" || bad "curl called without -f: $(cat "$TD/curl.calls" 2>/dev/null)"
FAKE_CURL_HTTP=200 NOTIFY_NOW=$(at "2026-09-07 10:05") notify_operator action "service down" "HTTP 503"
grep -q 'SENT action 4 service down' "$TD/log" && [ -f "$TD/st/action.service_down" ] && ok "HTTP 200: SENT and the cooldown opens (control)" || bad "HTTP 200 not SENT: $(tail -2 "$TD/log")"

# 14. the queue is locked: an action queued while a flush is pushing survives the flush. The stand-in
#     push takes 1 s and, meanwhile, another process queues an out-of-hours action. Before the lock the
#     flush truncated the queue after the push and that line was lost while its cooldown stamp stayed.
reset; mkdir -p "$TD/st"
NOTIFY_NOW=$(at "2026-09-05 22:10") notify_operator action "backup not pushed" "19 days"
late_cmd=". '$repo/bin/lib/notify.sh'; NOTIFY_NOW=$(at "2026-09-06 07:30") notify_operator action 'late arrival' 'queued during the push'"
FAKE_CURL_HOOK="$late_cmd" FAKE_CURL_HOOK_PID="$TD/hook.pid" FAKE_CURL_SLEEP=1 NOTIFY_NOW=$(at "2026-09-07 07:00") notify_flush
hp="$(cat "$TD/hook.pid" 2>/dev/null)"
for _ in $(seq 1 100); do [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null || break; sleep 0.1; done
grep -q 'FLUSHED 1 queued actions' "$TD/log" && ok "flush pushed the one line queued before it" || bad "flush wrong: $(grep FLUSH "$TD/log")"
[ "$(wc -l < "$TD/st/queue")" = 1 ] && grep -q 'late arrival' "$TD/st/queue" && ok "the action queued during the push is still queued" || bad "line queued during the push lost: queue=$(cat "$TD/st/queue" 2>/dev/null)"
fl="$(grep -n 'FLUSHED' "$TD/log" | cut -d: -f1)"; ql="$(grep -n 'QUEUED action late arrival' "$TD/log" | cut -d: -f1)"
[ -n "$fl" ] && [ -n "$ql" ] && [ "$ql" -gt "$fl" ] && ! grep -q LOCK-SKIPPED "$TD/log" && ok "the late enqueue waited for the flush's lock" || bad "not serialized by the lock: $(cat "$TD/log")"
[ ! -e "$TD/st/queue.tmp" ] && ok "no temp file left after the flush" || bad "queue.tmp left behind"
export PATH="$OLDPATH" NOTIFY_SINK="$TD/sink"; unset NTFY_URL FAKE_CURL_CALLS

# 15. the digest is capped: past NOTIFY_DIGEST_MAX_LINES the oldest lines go, down to 90% of the cap,
#     with a logged count. Without a --digest cron the file grew without bound.
reset
for i in $(seq 1 11); do NOTIFY_DIGEST_MAX_LINES=10 NOTIFY_NOW=$(at "2026-09-07 10:00") notify_operator info "event $i" "n$i"; done
[ "$(wc -l < "$TD/st/digest")" = 9 ] && ok "digest trimmed to 90% of the cap" || bad "digest has $(wc -l < "$TD/st/digest") lines, want 9"
grep -q 'event 11 :: n11' "$TD/st/digest" && ! grep -q 'event 2 :: n2$' "$TD/st/digest" && ok "the oldest lines dropped, the newest kept" || bad "wrong lines kept: $(head -2 "$TD/st/digest")"
grep -q 'DIGEST-TRIMMED 2 oldest info line(s) dropped' "$TD/log" && ok "trim logged with the count" || bad "trim not logged: $(grep TRIM "$TD/log")"
NOTIFY_DIGEST_MAX_LINES=10 NOTIFY_NOW=$(at "2026-09-07 10:01") notify_operator info "event 12" "n12"
[ "$(wc -l < "$TD/st/digest")" = 10 ] && [ "$(grep -c DIGEST-TRIMMED "$TD/log")" = 1 ] && ok "at the cap: appended, no second trim" || bad "second trim or wrong length"

# 16. notify_mute_epoch: the one parse behind notify_muted and --mute.
v="$(notify_mute_epoch 1790000000)" && [ "$v" = 1790000000 ] && ok "mute: epoch accepted as is" || bad "mute epoch: '$v'"
v="$(notify_mute_epoch '2026-09-07 08:30 UTC')" && [ "$v" = "$(date -u -d '2026-09-07 08:30' +%s)" ] && ok "mute: date string resolved" || bad "mute date string: '$v'"
notify_mute_epoch 'next tuesdai' >/dev/null && bad "mute: a typo parsed" || ok "mute: a typo does not parse"
notify_mute_epoch '' >/dev/null && bad "mute: empty parsed" || ok "mute: empty does not parse"

[ "$fail" = 0 ] && echo "notify.test: PASS" || { echo "notify.test: FAIL"; exit 1; }

#!/usr/bin/env bash
# Regression test for bin/hooks/gate-outbound-reply.sh: the four messages of the
# 2026-09-11 08:19-08:27 exchange, replayed against the gate. Hermetic:
# temp TEAM_DIR, no network, no tmux. Run: bin/tests/gate-outbound-reply.test.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$repo/bin/hooks/gate-outbound-reply.sh"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
export TEAM_DIR="$TD"; mkdir -p "$TD/health"
# The test brings its own recipient allow-list (the fixtures below), so it runs the same
# in this repo and in any deployment; the live list is the deployment dir or config/.
export OUTBOUND_ALLOWLIST="$TD/allowlist.txt"
# Deployment patterns for the credential check (python regexes, one capture group).
export GATE_URL_RE='example-gate\?p=([A-Za-z0-9!._~-]+)' GATE_LOGIN_RE='admin@example\.com\s*/\s*`?([^\s`<]+)'
cat > "$OUTBOUND_ALLOWLIST" <<'EOF2'
19:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@thread.v2          # group chat fixture
48:notes                                               # self-chat fixture
19:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@thread.tacv2   # channel fixture
*@example.com                                           # mail domain fixture
EOF2
fail=0; ok() { printf '  ok   %s\n' "$1"; }; bad() { printf '  FAIL %s\n' "$1"; fail=1; }
chat='19:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@thread.v2'
call() { # call <tool> <chat_id> <body_html> -> exit code; stderr captured in $out
  local tool="$1" cid="$2" body="$3"
  out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"chat_id": sys.argv[2], "body_html": sys.argv[3]}}))' "$tool" "$cid" "$body" | bash "$GATE" 2>&1 >/dev/null)"
  return $?
}
GATEVAL='GateValue-Fixture-9'; PW='Secret-Value-1'; STALEPW='PreprodAccess2026-Old'
m1="<p>Login: <code>admin@example.com</code> / <code>$STALEPW</code></p><p>Before logging in, open this URL once: https://preprod.example.com/example-gate?p=GateValue-Old</p>"
m2="<p>Checking now. Quick question: did you visit the gate URL first, or did you go straight to the login page?</p>"
m3="<p>The gate URL I just sent should work now, but the app login password has also changed. Checking the current password from inside the server — will follow up in a few minutes.</p>"
m4="<p>Found it. Gate: https://preprod.example.com/example-gate?p=$GATEVAL Login: admin@example.com / $PW. Both verified just now.</p>"

echo "1. credential quoted from a document, nothing measured -> blocked"
call mcp__ms365__teams_chat_send "$chat" "$m1"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"env-login-probe"* ]] && ok "unmeasured credential blocked, probe named" || bad "expected block (rc=$rc): $out"

echo "2. the same credentials after a fresh probe record -> allowed"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"preprod": {"gate": "%s", "password": "%s", "verified_at": "%s"}}' "$GATEVAL" "$PW" "$now" > "$TD/health/env-logins.json"
call mcp__ms365__teams_chat_send "$chat" "$m4"; rc=$?
[ "$rc" = 0 ] && ok "fresh measured credentials pass" || bad "expected pass (rc=$rc): $out"

echo "3. a stale probe record (20 minutes) -> blocked"
old="$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"preprod": {"gate": "%s", "password": "%s", "verified_at": "%s"}}' "$GATEVAL" "$PW" "$old" > "$TD/health/env-logins.json"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "$m4"; rc=$?
[ "$rc" = 2 ] && ok "stale record blocked" || bad "expected block on stale record (rc=$rc)"

echo "4. asking the requester to re-check her own step -> blocked"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "$m2"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"re-check"* ]] && ok "deflection blocked" || bad "expected block (rc=$rc): $out"

echo "5. 'will follow up in a few minutes' without a time -> blocked"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "$m3"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"clock time"* ]] && ok "hollow promise blocked" || bad "expected block (rc=$rc): $out"

echo "6. a bounded status line with a clock time -> allowed"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "<p>Checking the app password from inside the box; answer by 08:35.</p>"; rc=$?
[ "$rc" = 0 ] && ok "bounded status line passes" || bad "expected pass (rc=$rc): $out"

echo "7. one message per reply: a second send inside 60s after a SUCCESSFUL send -> blocked; after a FAILED attempt -> allowed; other chat -> allowed"
RECORD="$repo/bin/hooks/record-outbound-send.sh"
record() { # record <tool> <chat_id> <response-json> : the PostToolUse recorder
  python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"chat_id": sys.argv[2], "body_html": "x"}, "tool_response": json.loads(sys.argv[3])}))' "$1" "$2" "$3" | bash "$RECORD" >/dev/null 2>&1
}
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "<p>VAGUE 1: two tickets ready.</p>"; rc1=$?
record mcp__ms365__teams_chat_send "$chat" '{"status":"sent","message_id":"1"}'
call mcp__ms365__teams_chat_send "$chat" "<p>VAGUE 2: three more.</p>"; rc2=$?
call mcp__ms365__teams_chat_send "48:notes" "<p>unrelated, to a listed chat</p>"; rc3=$?
[ "$rc1" = 0 ] && [ "$rc2" = 2 ] && [ "$rc3" = 0 ] && ok "burst after a successful send blocked, other chat allowed" || bad "burst rule wrong (rc1=$rc1 rc2=$rc2 rc3=$rc3): $out"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "<p>first attempt, the connector fails</p>"; rcA=$?
record mcp__ms365__teams_chat_send "$chat" '{"error":{"type":"upstream_error","message":"Requested API is not allowed"}}'
call mcp__ms365__teams_chat_send "$chat" "<p>real reply right after the failed attempt</p>"; rcB=$?
[ "$rcA" = 0 ] && [ "$rcB" = 0 ] && ok "a failed attempt does not count as a send (the 10:06 case)" || bad "failed attempt still blocks (rcA=$rcA rcB=$rcB): $out"
record mcp__ms365__teams_chat_send "$chat" '{"status":"sent","message_id":"2"}'
GATE_SEND_MIN_GAP_SEC=0 call mcp__ms365__teams_chat_send "$chat" "<p>after the gap</p>"; rc=$?
[ "$rc" = 0 ] && ok "send after the gap passes" || bad "expected pass after gap (rc=$rc)"

echo "8. an ordinary message -> allowed; mail with an unmeasured password -> blocked"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "$chat" "<p>#5062 covers adding crew code, assignment number and base station to the onboarding page.</p>"; rc=$?
[ "$rc" = 0 ] && ok "ordinary message passes" || bad "ordinary message blocked (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__mail_send", "tool_input": {"to": "someone@other.test", "body": "Login admin@example.com / NotMeasured-99"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && ok "mail with an unmeasured password blocked" || bad "mail credential not blocked (rc=$rc)"

echo "9. disabled switch and empty body -> allowed"
out="$(printf '{"tool_name":"mcp__ms365__teams_chat_send","tool_input":{"chat_id":"x","body_html":""}}' | bash "$GATE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "empty body passes" || bad "empty body blocked (rc=$rc)"
out="$(GATE_OUTBOUND_REPLY_DISABLED=1 python3 -c 'import json; print(json.dumps({"tool_name":"mcp__ms365__teams_chat_send","tool_input":{"chat_id":"x","body_html":"<p>did you visit the gate</p>"}}))' | GATE_OUTBOUND_REPLY_DISABLED=1 bash "$GATE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "disabled switch passes" || bad "disabled switch still blocks (rc=$rc)"

echo "10. recipient allow-list (rule 10): listed chat passes, an unlisted chat is blocked, mail by domain"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_send "19:cccccccccccccccccccccccccccccccc@thread.v2" "<p>hello team</p>"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"RULE 10"* ]] && ok "unlisted group chat (an unlisted group) blocked" || bad "unlisted chat not blocked (rc=$rc): $out"
call mcp__ms365__teams_chat_send "$chat" "<p>hello</p>"; rc=$?
[ "$rc" = 0 ] && ok "listed group chat passes" || bad "listed chat blocked (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__teams_channel_send", "tool_input": {"team_id": "team-fixture", "channel_id": "19:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@thread.tacv2", "body_html": "<p>PR is ready</p>"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "listed channel passes" || bad "listed channel blocked (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__mail_send", "tool_input": {"to": ["manager@example.com"], "subject": "x", "body": "plain text"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "mail to the listed domain passes" || bad "mail to the listed domain blocked (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__mail_send", "tool_input": {"to": ["someone@other.test"], "subject": "x", "body": "plain text"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"RULE 10"* ]] && ok "mail to an outside domain blocked" || bad "outside mail not blocked (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__mail_send", "tool_input": {"to": ["manager@example.com"], "cc": "vendor@other.test", "subject": "x", "body": "plain text"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && ok "an outside cc is blocked too" || bad "outside cc not blocked (rc=$rc)"

echo "11. the right tool for the id: teams_chat_reply refused; chat_send on a channel id refused; channel_reply on a chat id refused"
rm -f "$TD"/health/outbound-last-send.*
call mcp__ms365__teams_chat_reply "$chat" "<p>reply attempt</p>"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"TOOL (gate)"* ]] && ok "teams_chat_reply refused with guidance" || bad "teams_chat_reply not refused (rc=$rc): $out"
call mcp__ms365__teams_chat_send "19:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@thread.tacv2" "<p>to a channel via chat_send</p>"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"CHANNEL"* ]] && ok "chat_send on a channel id refused" || bad "chat_send on channel id not refused (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__teams_channel_reply", "tool_input": {"team_id": "t", "channel_id": "19:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@thread.v2", "message_id": "1", "body_html": "<p>x</p>"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"not a channel"* ]] && ok "channel_reply on a chat id refused" || bad "channel_reply on chat id not refused (rc=$rc): $out"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__ms365__teams_channel_reply", "tool_input": {"team_id": "t", "channel_id": "19:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@thread.tacv2", "message_id": "1", "body_html": "<p>Fix ready: PR #3966 targeting dev.</p>"}}))' | bash "$GATE" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "channel_reply on a channel id passes" || bad "channel_reply on channel id blocked (rc=$rc): $out"

echo "12. no allow-list file at all -> everything blocked (the list is the permission)"
OUTBOUND_ALLOWLIST="$TD/missing.txt" call mcp__ms365__teams_chat_send "$chat" "<p>hello</p>"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"missing"* ]] && ok "missing allow-list blocks" || bad "missing allow-list did not block (rc=$rc): $out"

[ "$fail" = 0 ] && echo "gate-outbound-reply.test: PASS" || { echo "gate-outbound-reply.test: FAIL"; exit 1; }

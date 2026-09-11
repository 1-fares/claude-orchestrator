#!/usr/bin/env bash
# PostToolUse on the ms365 Teams send tools: record the time of a SUCCESSFUL send per
# chat/channel, for check 3 (one message per reply) of bin/hooks/gate-outbound-reply.sh.
#
# WHY a separate PostToolUse hook: the PreToolUse gate cannot know whether the send
# will succeed. On 2026-09-11 10:06 the orchestrator tried teams_chat_reply on a
# channel (the connector returns 404), the gate had already stamped the send, and the
# correct teams_channel_reply was blocked twice ("16 seconds ago", "32 seconds ago");
# the acknowledgement the requester should have had at 10:06 arrived at 10:16. A failed call
# is not a message anyone received.
#
# Success = the tool_response carries a message id or a "sent" status and no error.
. "$(dirname "$0")/hooks-common.sh"
input="$(cat)"
export TD="$_td"
printf '%s' "$input" | python3 -c '
import sys, json, re, os
d = json.load(sys.stdin)
name = d.get("tool_name", "")
if not (name.startswith("mcp__ms365__teams_") and name.endswith(("_send", "_reply"))):
    sys.exit(0)
t = d.get("tool_input", {}) or {}
key = t.get("chat_id") or t.get("channel_id") or ""
key = re.sub(r"[^A-Za-z0-9]", "_", str(key))[:80]
if not key:
    sys.exit(0)
resp = d.get("tool_response")
text = resp if isinstance(resp, str) else json.dumps(resp)
ok = ("message_id" in text or "\"status\": \"sent\"" in text or "\"status\":\"sent\"" in text) and "\"error\"" not in text
if not ok:
    sys.exit(0)
state_dir = os.path.join(os.environ["TD"], "health")
os.makedirs(state_dir, exist_ok=True)
import time
with open(os.path.join(state_dir, "outbound-last-send." + key), "w") as fh:
    fh.write(str(int(time.time())))
' 2>/dev/null
exit 0

#!/usr/bin/env bash
# PreToolUse on the ms365 send tools (teams_chat_send, teams_chat_reply,
# teams_channel_send, teams_channel_reply, mail_send, mail_reply): rules 13 and 14
# as a GATE, not a reminder. Exit 2 blocks the send and hands the reason to the model.
#
# WHY (2026-09-11 08:19-08:27 CEST, a manager's chat). Four outbound messages in eight
# minutes: a credential quoted from a document (401), "Quick question: did you visit
# the gate URL first?" (she had), a half-verified fix, then "will follow up in a few
# minutes". A rule in a memory file was read that morning and still not applied. A
# gate cannot be skimmed.
#
# Three checks on the outgoing body (HTML tags stripped):
#   1. CREDENTIAL FRESHNESS. Every environment-gate value and every shared-login
#      password in the body (patterns GATE_URL_RE and GATE_LOGIN_RE from
#      numeriq/gate-outbound.conf or config/gate-outbound.conf; no patterns = no
#      check) must appear in $TEAM_DIR/health/env-logins.json, written by the
#      deployment's login probe, with verified_at inside GATE_CRED_MAX_AGE_SEC
#      (default 900). Anything else is a quote from a document, and blocked.
#   2. NO HOLLOW OR DEFLECTING REPLIES. A body that asks the requester to re-check a
#      step the team can test ("did you visit", "have you tried", "make sure you") is
#      blocked outright. A body that promises later work ("will follow up", "in a few
#      minutes", "checking now", "let me check", "I'll get back") is blocked unless it
#      also names a clock time (HH:MM) by which the answer arrives.
#   3. ONE MESSAGE PER REPLY. A second send to the same chat or channel within
#      GATE_SEND_MIN_GAP_SEC (default 60) is blocked: merge it into one message.
#      State: $TEAM_DIR/health/outbound-last-send.<key>.
# Env: GATE_OUTBOUND_REPLY_DISABLED=1 skips everything (tests of other gates only).
. "$(dirname "$0")/hooks-common.sh"
input="$(cat)"   # read stdin before any early exit, or the caller gets a broken pipe
[ "${GATE_OUTBOUND_REPLY_DISABLED:-0}" = 1 ] && exit 0
# Deployment patterns (python regexes with one capture group): which strings in a
# body are an environment-gate value and which are a shared-login password.
# The environment wins over the conf (tests set their own patterns).
_env_url="${GATE_URL_RE-}"; _env_login="${GATE_LOGIN_RE-}"
for _c in "$_repo/numeriq/gate-outbound.conf" "$_repo/config/gate-outbound.conf"; do
  if [ -r "$_c" ]; then . "$_c"; break; fi
done
[ -n "$_env_url" ] && GATE_URL_RE="$_env_url"; [ -n "$_env_login" ] && GATE_LOGIN_RE="$_env_login"
export GATE_URL_RE="${GATE_URL_RE:-}" GATE_LOGIN_RE="${GATE_LOGIN_RE:-}"
max_age="${GATE_CRED_MAX_AGE_SEC:-900}"
min_gap="${GATE_SEND_MIN_GAP_SEC:-60}"
logins="$_td/health/env-logins.json"
state_dir="$_td/health"

# --- parse the tool call --------------------------------------------------------
parsed="$(printf '%s' "$input" | python3 -c '
import sys, json, re, html
d = json.load(sys.stdin)
t = d.get("tool_input", {}) or {}
name = d.get("tool_name", "")
body = t.get("body_html") or t.get("body") or t.get("text") or t.get("message") or ""
# strip tags, unescape entities, collapse whitespace
txt = re.sub(r"<[^>]+>", " ", body)
txt = html.unescape(txt)
txt = re.sub(r"\s+", " ", txt).strip()
key = t.get("chat_id") or t.get("channel_id") or t.get("to") or t.get("message_id") or ""
key = re.sub(r"[^A-Za-z0-9]", "_", str(key))[:80]
import os
strip = lambda v: re.sub(r"[.,;:)\]]+$", "", v)   # prose punctuation after a value
url_re = os.environ.get("GATE_URL_RE", ""); login_re = os.environ.get("GATE_LOGIN_RE", "")
gates = [strip(v) for v in re.findall(url_re, txt)] if url_re else []
pws = [strip(v) for v in re.findall(login_re, txt)] if login_re else []
print(json.dumps({"name": name, "txt": txt, "key": key, "gates": gates, "pws": pws}))
' 2>/dev/null)" || exit 0
[ -n "$parsed" ] || exit 0
get() { printf '%s' "$parsed" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('$1'); print(' '.join(v) if isinstance(v,list) else (v or ''))"; }
txt="$(get txt)"; key="$(get key)"; gates="$(get gates)"; pws="$(get pws)"
[ -n "$txt" ] || exit 0

block() { printf '%s\n' "$1" >&2; printf '%s\n' "$1"; exit 2; }

# --- 0a. the right tool for the id (measured 2026-09-11) -------------------------
# teams_chat_reply returns 404 on every chat here (Graph has no reply-to-message API
# for chats); a channel id (@thread.tacv2) needs the teams_channel_* tools with
# team_id; a chat id (@thread.v2, @unq.gbl.spaces) needs teams_chat_send. A wrong
# tool cost a ten-minute delay (10:06 on 2026-09-11), so it is refused up front.
tool="$(get name)"
case "$tool" in
  *teams_chat_reply)
    block "TOOL (gate): teams_chat_reply does not work on chats (Graph has no reply-to-message API for chats; measured 404 on 2026-09-11). Use teams_chat_send for a group chat, or teams_channel_reply (message_id = the thread root) for a channel." ;;
  *teams_chat_send)
    case "$key" in *_thread_tacv2*) block "TOOL (gate): this id is a CHANNEL (@thread.tacv2). Use teams_channel_reply (team_id, channel_id, message_id = the thread root) or teams_channel_send." ;; esac ;;
  *teams_channel_send|*teams_channel_reply)
    case "$key" in *_thread_v2*|*_unq_gbl_spaces*) block "TOOL (gate): this id is a chat, not a channel. Use teams_chat_send with chat_id." ;; esac ;;
esac

# --- 0b. recipient allow-list (rule 10: the operator's recipient list) -------------
# Every chat_id, channel_id and mail address of the call must match a line of the
# allow-list file (exact id, or *@domain for mail). A missing file blocks everything:
# the list is the permission. Path: $OUTBOUND_ALLOWLIST, else numeriq/ (this fork),
# else config/ (the engine default).
allow="${OUTBOUND_ALLOWLIST:-}"
[ -n "$allow" ] || { [ -r "$_repo/numeriq/outbound-allowlist.txt" ] && allow="$_repo/numeriq/outbound-allowlist.txt" || allow="$_repo/config/outbound-allowlist.txt"; }
targets="$(printf '%s' "$input" | python3 -c '
import sys, json, re
d = json.load(sys.stdin); t = d.get("tool_input", {}) or {}
out = []
for k in ("chat_id", "channel_id"):
    v = t.get(k)
    if v: out.append(str(v))
for k in ("to", "cc", "bcc", "recipients"):
    v = t.get(k)
    if isinstance(v, str): v = re.split(r"[;,\s]+", v)
    for a in (v or []):
        if isinstance(a, dict): a = a.get("address") or a.get("email") or ""
        a = str(a).strip()
        m = re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", a)
        if m: out.append(m.group(0).lower())
print("\n".join(out))
' 2>/dev/null)"
if [ -n "$targets" ]; then
  [ -r "$allow" ] || block "RULE 10 (gate): the recipient allow-list $allow is missing; nothing can be sent until it exists (one id or *@domain per line; creating it is an operator decision)."
  while IFS= read -r tgt; do
    [ -n "$tgt" ] || continue
    ok=0
    while IFS= read -r line; do
      pat="${line%%#*}"; pat="${pat//[[:space:]]/}"; [ -n "$pat" ] || continue
      case "$pat" in
        \*@*) [[ "$tgt" == *"@${pat#\*@}" ]] && { ok=1; break; } ;;
        *)    [ "$tgt" = "$pat" ] && { ok=1; break; } ;;
      esac
    done < "$allow"
    [ "$ok" = 1 ] || block "RULE 10 (gate): '$tgt' is not in the recipient allow-list ${allow#$_repo/} (the operator decides who the team may write to). If the operator decided otherwise, add the line there with the date and the words; do not send around the list."
  done <<< "$targets"
fi

# --- 1. credential freshness ----------------------------------------------------
if [ -n "$gates$pws" ]; then
  verdict="$(GATES="$gates" PWS="$pws" LOGINS="$logins" MAX_AGE="$max_age" python3 -c '
import os, json, time, calendar
gates = os.environ["GATES"].split(); pws = os.environ["PWS"].split()
try:
    d = json.load(open(os.environ["LOGINS"]))
except Exception:
    d = {}
now = time.time(); ok_g = set(); ok_p = set()
for env, rec in d.items():
    try:
        # verified_at is UTC ("...Z"): timegm, not mktime (the box runs in Europe/Zurich)
        ts = calendar.timegm(time.strptime(rec.get("verified_at", ""), "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        continue
    if now - ts <= float(os.environ["MAX_AGE"]):
        ok_g.add(rec.get("gate", "")); ok_p.add(rec.get("password", ""))
bad = [g for g in gates if g not in ok_g] + [p for p in pws if p not in ok_p]
print(" ".join(bad))
')"
  if [ -n "$verdict" ]; then
    block "RULE 13 (gate): this message quotes a credential that was not measured in the last $((max_age / 60)) minutes: $verdict. Run bin/checks/env-login-probe.sh <dev|preprod> now and quote ONLY what it prints (it records what it verified in health/env-logins.json). A document is a candidate list, not the answer."
  fi
fi

# --- 2. hollow or deflecting replies --------------------------------------------
low="$(printf '%s' "$txt" | tr '[:upper:]' '[:lower:]')"
if printf '%s' "$low" | grep -qE "did you (visit|open|try|click|use|go|log)|have you (tried|visited|opened|checked)|make sure you|can you (try|check|confirm) (again|the|that|whether|if)|could you (try|check|confirm)"; then
  block "RULE 13 (gate): this message asks the requester to re-check a step you can test yourself (curl the gate for Set-Cookie, POST the login and read the status). Test it, then send the verified answer in one message."
fi
if printf '%s' "$low" | grep -qE "will follow up|follow up in|in a few minutes|checking now|let me check|i'?ll get back|give me a (few|couple|moment)|one moment|checking from|looking into (it|this)|working on it"; then
  if ! printf '%s' "$txt" | grep -qE "\b([01]?[0-9]|2[0-3]):[0-5][0-9]\b"; then
    block "RULE 14 (gate): this message promises later work without a time. Either send the verified answer, or one line that says what is being checked and the clock time (HH:MM) by which the answer arrives, with that check already running."
  fi
fi

# --- 3. one message per reply ---------------------------------------------------
# The timestamp of the last SUCCESSFUL send is written by the PostToolUse hook
# bin/hooks/record-outbound-send.sh, never here: on 2026-09-11 10:06 a reply attempted
# with the wrong tool (teams_chat_reply on a channel, 404) was counted as a send, the
# real reply was blocked twice, and the requester waited nine minutes for the acknowledgement.
case "$(get name)" in
  *teams_chat_send|*teams_chat_reply|*teams_channel_send|*teams_channel_reply)
    if [ -n "$key" ]; then
      f="$state_dir/outbound-last-send.$key"; now=$(date +%s)
      last=$(cat "$f" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0;; esac
      if [ $((now - last)) -lt "$min_gap" ]; then
        block "RULE 14 (gate): you sent a message to this chat $((now - last)) seconds ago. One reply per request, as one message: merge this into it (edit, or send one consolidated message after ${min_gap}s)."
      fi
    fi ;;
esac
exit 0

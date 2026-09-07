#!/usr/bin/env bash
# bin/lib/notify.sh — the one path to the operator's phone (ntfy). Sourced by daemons;
# bin/notify-operator.sh is the CLI front to the same functions.
#
# WHY (2026-09-07). In one morning the operator's phone received 38 pushes: 26 at
# priority urgent for five self-healable stale watches (one per watch per hour), 11
# from a planned relaunch the operator had just performed himself, one usage-band
# refusal fired at the exact reset instant. Nothing distinguished "a human must act
# now" from "a daemon restarted a daemon", no maintenance mute existed, and the only
# history was ntfy.sh's 12-hour cache. Three classes, declared at the call site:
#
#   page   (ntfy 5)  a human must act NOW: production impact, data exposure, the team
#                    dead beyond self-heal, a delivery failure. Re-pages every
#                    NOTIFY_PAGE_REPEAT_SEC until notify_resolved. Ignores working hours;
#                    during a maintenance mute it still goes, prefixed [maintenance].
#   action (ntfy 4)  a human must act TODAY: only the operator holds the key, decision or
#                    credential. One push per subject per NOTIFY_ACTION_COOLDOWN_SEC;
#                    queued outside working hours; dropped (logged) during a mute.
#   info   (ntfy 2)  everything else. Never pushed on its own: appended to a digest that
#                    notify_digest pushes ONCE a day at silent priority (cron, 08:00 Mon-Fri).
#
# Deny by default: notify_legacy, the compatibility shim for the daemons' old one-argument
# notify "<emoji> [daemon/run] text", maps 🔴 to action and everything else to info.
# Nothing pages unless a call site says page.
#
# API (TEAM_DIR must be set):
#   notify_operator <class> <subject> <body> [tags]
#   notify_resolved <subject> [body]   clears state; pushes priority 3 "resolved" if a page was sent
#   notify_flush                       pushes queued actions once working hours begin
#   notify_digest                      notify_flush, then one silent digest of the info lines
#   notify_legacy <text>               compatibility shim (see above)
#   notify_muted                       exit 0 while $NOTIFY_MUTE_FILE names a future instant
# Env:
#   NTFY_URL                 topic; unset = log only (every decision still lands in the log)
#   NOTIFY_SINK              file; "prio|title|body" appended instead of pushing (tests)
#   NOTIFY_LOG               default $TEAM_DIR/reports/operator-pings.log
#   NOTIFY_STATE_DIR         default $TEAM_DIR/health/notify (dedupe stamps, queue, digest)
#   NOTIFY_MUTE_FILE         default $TEAM_DIR/health/maintenance-until; first line is an epoch
#                            or a `date -d` string; an operator writes it before planned work
#   NOTIFY_HOURS=0700-1900   NOTIFY_DAYS=1-5   NOTIFY_TZ=Europe/Zurich
#   NOTIFY_ACTION_COOLDOWN_SEC=21600   NOTIFY_PAGE_REPEAT_SEC=1800
#   NOTIFY_SOURCE            daemon name; subject prefix for notify_legacy
#   NOTIFY_NOW               epoch override for tests
# Log line: <utc> | <DECISION> <class> [<prio>] <subject> :: <body>
#   DECISION: SENT LOG-ONLY DEDUPE MUTED QUEUED DIGEST FLUSHED RESOLVED CLEARED BAD-CLASS

_nt_now()  { printf '%s' "${NOTIFY_NOW:-$(date +%s)}"; }
_nt_ts()   { date -u -d "@$(_nt_now)" +%Y-%m-%dT%H:%M:%SZ; }
_nt_dir()  { printf '%s' "${NOTIFY_STATE_DIR:-${TEAM_DIR:-.}/health/notify}"; }
_nt_key()  { printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_' | cut -c1-120; }
_nt_read() { cat "$1" 2>/dev/null || echo 0; }
_nt_log() {
  local f="${NOTIFY_LOG:-${TEAM_DIR:-.}/reports/operator-pings.log}"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s | %s\n' "$(_nt_ts)" "$*" >> "$f" 2>/dev/null || true
}

notify_muted() {
  local f="${NOTIFY_MUTE_FILE:-${TEAM_DIR:-.}/health/maintenance-until}" v
  [ -f "$f" ] || return 1
  v="$(head -1 "$f" 2>/dev/null)"
  case "$v" in ''|*[!0-9]*) v="$(date -d "$v" +%s 2>/dev/null || echo 0)" ;; esac
  [ "$(_nt_now)" -lt "$v" ]
}

_nt_in_hours() {
  local tz="${NOTIFY_TZ:-Europe/Zurich}" hours="${NOTIFY_HOURS:-0700-1900}" days="${NOTIFY_DAYS:-1-5}"
  local dow hm
  dow="$(TZ="$tz" date -d "@$(_nt_now)" +%u)"; hm="$(TZ="$tz" date -d "@$(_nt_now)" +%H%M)"
  [ "$dow" -ge "${days%-*}" ] && [ "$dow" -le "${days#*-}" ] \
    && [ "$((10#$hm))" -ge "$((10#${hours%-*}))" ] && [ "$((10#$hm))" -lt "$((10#${hours#*-}))" ]
}

# _nt_push <prio> <title> <body> [tags]: the only place that talks to ntfy.
_nt_push() {
  local prio="$1" title="$2" body="$3" tags="${4:-}"
  if [ -n "${NOTIFY_SINK:-}" ]; then printf '%s|%s|%s\n' "$prio" "$title" "$(printf '%s' "$body" | tr '\n' ' ')" >> "$NOTIFY_SINK"; return 0; fi
  [ -n "${NTFY_URL:-}" ] || return 1
  if [ -n "$tags" ]; then
    curl -sS -m 10 -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" --data-raw "$body" "$NTFY_URL" -o /dev/null 2>/dev/null
  else
    curl -sS -m 10 -H "Title: $title" -H "Priority: $prio" --data-raw "$body" "$NTFY_URL" -o /dev/null 2>/dev/null
  fi
}

notify_operator() {
  local class="${1:-}" subject="${2:-}" body="${3:-}" tags="${4:-}"
  local now key st last title run
  [ -n "$class" ] && [ -n "$subject" ] || return 2
  now="$(_nt_now)"; run="${TEAM_RUN_ID:-team}"; title="[$run] $subject"
  mkdir -p "$(_nt_dir)" 2>/dev/null || true
  key="$(_nt_key "$subject")"
  case "$class" in
    page)
      st="$(_nt_dir)/page.$key"; last="$(_nt_read "$st")"
      if [ $((now - last)) -lt "${NOTIFY_PAGE_REPEAT_SEC:-1800}" ]; then _nt_log "DEDUPE page $subject :: $body"; return 0; fi
      notify_muted && title="[maintenance] $title"
      printf '%s' "$now" > "$st"
      if _nt_push 5 "$title" "$body" "${tags:-rotating_light}"; then _nt_log "SENT page 5 $subject :: $body"; else _nt_log "LOG-ONLY page $subject :: $body"; fi ;;
    action)
      if notify_muted; then _nt_log "MUTED action $subject :: $body"; return 0; fi
      st="$(_nt_dir)/action.$key"; last="$(_nt_read "$st")"
      if [ $((now - last)) -lt "${NOTIFY_ACTION_COOLDOWN_SEC:-21600}" ]; then _nt_log "DEDUPE action $subject :: $body"; return 0; fi
      printf '%s' "$now" > "$st"
      if ! _nt_in_hours; then
        printf '%s\t%s\t%s\n' "$(_nt_ts)" "$subject" "$body" >> "$(_nt_dir)/queue"
        _nt_log "QUEUED action $subject :: $body"; return 0
      fi
      if _nt_push 4 "$title" "$body" "${tags:-warning}"; then _nt_log "SENT action 4 $subject :: $body"; else _nt_log "LOG-ONLY action $subject :: $body"; fi ;;
    info)
      printf '%s %s :: %s\n' "$(_nt_ts)" "$subject" "$body" >> "$(_nt_dir)/digest"
      _nt_log "DIGEST info $subject :: $body" ;;
    *) _nt_log "BAD-CLASS $class $subject :: $body"; return 2 ;;
  esac
}

notify_resolved() {
  local subject="${1:-}" body="${2:-resolved}" key st
  [ -n "$subject" ] || return 2
  key="$(_nt_key "$subject")"; st="$(_nt_dir)/page.$key"
  if [ -f "$st" ]; then
    rm -f "$st"
    if _nt_push 3 "[${TEAM_RUN_ID:-team}] resolved: $subject" "$body" "white_check_mark"; then _nt_log "RESOLVED page $subject :: $body"; else _nt_log "RESOLVED-LOG-ONLY page $subject :: $body"; fi
  else
    rm -f "$(_nt_dir)/action.$key"; _nt_log "CLEARED $subject :: $body"
  fi
}

notify_flush() {
  local q="$(_nt_dir)/queue" n body
  [ -s "$q" ] || return 0
  _nt_in_hours || return 0
  n=$(wc -l < "$q"); body="$(cut -f2- "$q" | tr '\t' ':' | head -c 3800)"
  if _nt_push 4 "[${TEAM_RUN_ID:-team}] $n action(s) queued out of hours" "$body" "warning"; then : > "$q"; _nt_log "FLUSHED $n queued actions"; else _nt_log "FLUSH-FAILED $n queued actions"; fi
}

notify_digest() {
  local d="$(_nt_dir)/digest" n body
  notify_flush
  [ -s "$d" ] || { _nt_log "DIGEST-EMPTY"; return 0; }
  n=$(wc -l < "$d"); body="$(cut -d' ' -f2- "$d" | head -c 3800)"
  if _nt_push 2 "[${TEAM_RUN_ID:-team}] daily digest: $n info event(s)" "$body" "page_facing_up"; then
    mv -f "$d" "$d.$(TZ="${NOTIFY_TZ:-Europe/Zurich}" date -d "@$(_nt_now)" +%Y%m%d)"; _nt_log "DIGEST-SENT $n items"
  else _nt_log "DIGEST-FAILED $n items"; fi
}

# notify_legacy <text>: the daemons' old notify "<emoji> [daemon/run] text". 🔴 = action,
# else info. The subject is the text after the bracket with digits stripped, so
# "FREEZE: burn 93%" and "FREEZE: burn 94%" dedupe together.
notify_legacy() {
  local text="$*" class=info subject
  case "$text" in "🔴"*) class=action ;; esac
  subject="${NOTIFY_SOURCE:-legacy}: $(printf '%s' "$text" | sed -E 's/^[^]]*\] *//' | tr -d '0-9' | cut -c1-56)"
  notify_operator "$class" "$subject" "$text"
}

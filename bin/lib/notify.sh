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
#                    dead beyond self-heal, a delivery failure. A repeat for the same
#                    subject is pushed again once NOTIFY_PAGE_REPEAT_SEC has passed. Ignores
#                    working hours; during a maintenance mute it still goes, prefixed [maintenance].
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
#   notify_resolved <subject> [body]   clears state and drops the subject's queued lines; pushes
#                                      priority 3 "resolved" if a page was sent. NOTHING in this
#                                      repository calls it, so no "resolved" push is ever sent;
#                                      kept for bin/tests/notify.test.sh and for a sender that
#                                      wants to clear a page or a queued action
#   notify_flush                       pushes queued actions once working hours begin
#   notify_digest                      notify_flush, then one silent digest of the info lines
#   notify_legacy <text>               compatibility shim (see above)
#   notify_muted                       exit 0 while $NOTIFY_MUTE_FILE names a future instant
#   notify_mute_epoch <value>          the mute instant as epoch seconds; exit 1 if it does not parse
# Env:
#   NTFY_URL                 topic; unset = log only (every decision still lands in the log)
#   NOTIFY_SINK              file; "prio|title|body" appended instead of pushing (tests)
#   NOTIFY_LOG               default $TEAM_DIR/reports/operator-pings.log; with NOTIFY_SINK set
#                            and NOTIFY_LOG unset, ${NOTIFY_SINK}.log, so a test or a hand run
#                            never writes where the operator and the digest read
#   NOTIFY_STATE_DIR         default $TEAM_DIR/health/notify (dedupe stamps, queue, digest); with
#                            NOTIFY_SINK set and NOTIFY_STATE_DIR unset, ${NOTIFY_SINK}.state, so a
#                            fixture never lands in the digest the daily cron pushes
#   NOTIFY_MUTE_FILE         default $TEAM_DIR/health/maintenance-until; first line is an epoch
#                            or a `date -d` string; an operator writes it before planned work
#   NOTIFY_HOURS=0700-1900   NOTIFY_DAYS=1-5   NOTIFY_TZ=Europe/Zurich
#   NOTIFY_ACTION_COOLDOWN_SEC=21600   NOTIFY_PAGE_REPEAT_SEC=1800
#   NOTIFY_DIGEST_MAX_LINES=1000  cap on the info digest; an append that takes it past the cap
#                            drops the oldest lines down to 90% of it and logs DIGEST-TRIMMED
#                            with the count (the digest grows without bound when no --digest
#                            cron is installed). 0 = no cap
#   NOTIFY_ACTION_SOURCES    space-separated NOTIFY_SOURCE names whose `action` is pushed
#                            audibly; every other sender's action is demoted to info and
#                            logged as DEMOTED. Unset, "" or "*" = every sender (default).
#                            A deployment that found its operator paged for deploy
#                            results, backup age and audit findings sets this to the two
#                            or three senders that really need a human the same day.
#   NOTIFY_SOURCE            daemon name; subject prefix for notify_legacy
#   NOTIFY_NOW               epoch override for tests
# Log line: <utc> | <DECISION> <class> [<prio>] <subject> :: <body>
#   DECISION: SENT LOG-ONLY DEDUPE MUTED QUEUED DIGEST DEMOTED BAD-CLASS (notify_operator);
#   RESOLVED RESOLVED-LOG-ONLY CLEARED UNQUEUED UNQUEUE-NOMATCH UNQUEUE-FAILED (notify_resolved);
#   FLUSHED FLUSH-FAILED DIGEST-SENT DIGEST-FAILED DIGEST-EMPTY (notify_flush, notify_digest);
#   PUSH-FAIL (a push that curl or the service refused), DIGEST-TRIMMED, LOCK-SKIPPED

_nt_now()  { printf '%s' "${NOTIFY_NOW:-$(date +%s)}"; }
_nt_ts()   { date -u -d "@$(_nt_now)" +%Y-%m-%dT%H:%M:%SZ; }
# A sinked caller is a test or a hand run: its state and log stay beside the sink, never under the
# live TEAM_DIR. Without this a sinked run that inherits a live TEAM_DIR writes fixture lines into
# the operator's log and stamps the real dedupe files. /dev/null gets throwaway locations of its own.
_nt_sinked() { [ -n "${NOTIFY_SINK:-}" ]; }
_nt_dir() {
  if [ -n "${NOTIFY_STATE_DIR:-}" ]; then printf '%s' "$NOTIFY_STATE_DIR"
  elif _nt_sinked; then
    case "$NOTIFY_SINK" in
      /dev/null) printf '%s' "${TMPDIR:-/tmp}/notify-devnull-state-$(id -u)" ;;
      *) printf '%s' "${NOTIFY_SINK}.state" ;;
    esac
  else printf '%s' "${TEAM_DIR:-.}/health/notify"; fi
}
_nt_key()  { printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_' | cut -c1-120; }
_nt_read() { cat "$1" 2>/dev/null || echo 0; }
# Queue length after a mutation. Every queue mutation logs "[queue now N]" so a change nobody
# logged can be named afterwards.
_nt_qlen() { local q="$(_nt_dir)/queue"; if [ -f "$q" ]; then wc -l < "$q" | tr -d ' '; else echo 0; fi; }
# _NT_LAST holds the line this shell logged last, so a caller (bin/notify-operator.sh) reads its OWN
# decision; the log's last line can be another sender's.
_nt_log() {
  local f
  if [ -n "${NOTIFY_LOG:-}" ]; then f="$NOTIFY_LOG"
  elif _nt_sinked; then case "$NOTIFY_SINK" in /dev/null) f=/dev/null ;; *) f="${NOTIFY_SINK}.log" ;; esac
  else f="${TEAM_DIR:-.}/reports/operator-pings.log"; fi
  _NT_LAST="$(_nt_ts) | $*"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s\n' "$_NT_LAST" >> "$f" 2>/dev/null || true
}

# _nt_locked <name> <fn> [args]: run fn in THIS shell (so _NT_LAST survives) holding
# <state dir>/<name>.lock. Several daemons append to, flush, unqueue and trim the same queue and
# digest files; without the lock a line appended while a flush pushed (up to 10 s) was truncated
# away with the pushed lines, its cooldown stamp still set. The 12 s wait outlasts the longest
# holder, a push bounded by curl -m 10. A lock that cannot be taken (unwritable dir, no flock,
# timeout) runs fn anyway and logs LOCK-SKIPPED: a line kept without the lock beats a line lost.
_nt_locked() {
  local lf fd rc=0
  lf="$(_nt_dir)/$1.lock"; shift
  if { : >> "$lf"; } 2>/dev/null && exec {fd}>>"$lf"; then
    flock -w 12 "$fd" 2>/dev/null || _nt_log "LOCK-SKIPPED ${lf##*/} (flock rc=$?); running unlocked"
    "$@" || rc=$?
    exec {fd}>&-
  else
    _nt_log "LOCK-SKIPPED ${lf##*/} (cannot open the lock file); running unlocked"
    "$@" || rc=$?
  fi
  return "$rc"
}

# notify_mute_epoch <value>: the mute instant as epoch seconds, from an epoch or anything
# `date -d` accepts; exit 1 when it does not resolve. The one parse behind notify_muted and
# `notify-operator.sh --mute`, so the CLI refuses exactly what the policy would read as no mute.
notify_mute_epoch() {
  case "$1" in
    '') return 1 ;;
    *[!0-9]*) date -d "$1" +%s 2>/dev/null ;;
    *) printf '%s\n' "$1" ;;
  esac
}

notify_muted() {
  local f="${NOTIFY_MUTE_FILE:-${TEAM_DIR:-.}/health/maintenance-until}" v
  [ -f "$f" ] || return 1
  v="$(notify_mute_epoch "$(head -1 "$f" 2>/dev/null)")" || return 1
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
# -f: without it curl exits 0 on an HTTP 4xx or 5xx, so a push the service refused counted as
# delivered (logged SENT, the cooldown opened, notify-operator.sh said DELIVERED). A failure logs
# PUSH-FAIL with curl's exit code and the HTTP status; the URL is never logged (it holds the topic).
_nt_push() {
  local prio="$1" title="$2" body="$3" tags="${4:-}" rc=0 code
  if [ -n "${NOTIFY_SINK:-}" ]; then printf '%s|%s|%s\n' "$prio" "$title" "$(printf '%s' "$body" | tr '\n' ' ')" >> "$NOTIFY_SINK"; return 0; fi
  [ -n "${NTFY_URL:-}" ] || return 1
  if [ -n "$tags" ]; then
    code="$(curl -fsS -m 10 -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" --data-raw "$body" "$NTFY_URL" -o /dev/null -w '%{http_code}' 2>/dev/null)" || rc=$?
  else
    code="$(curl -fsS -m 10 -H "Title: $title" -H "Priority: $prio" --data-raw "$body" "$NTFY_URL" -o /dev/null -w '%{http_code}' 2>/dev/null)" || rc=$?
  fi
  [ "$rc" -eq 0 ] || _nt_log "PUSH-FAIL curl rc=$rc http=${code:-none} :: $title"
  return "$rc"
}

# _nt_action_allowed: exit 0 iff the calling sender (NOTIFY_SOURCE) may push an
# audible action. Unset, "" or "*" NOTIFY_ACTION_SOURCES = every sender.
_nt_action_allowed() {
  local allow="${NOTIFY_ACTION_SOURCES-}" s
  [ -z "$allow" ] || [ "$allow" = "*" ] && return 0
  for s in $allow; do [ "$s" = "${NOTIFY_SOURCE:-}" ] && return 0; done
  return 1
}

notify_operator() {
  local class="${1:-}" subject="${2:-}" body="${3:-}" tags="${4:-}"
  local now key st last title run
  [ -n "$class" ] && [ -n "$subject" ] || return 2
  now="$(_nt_now)"; run="${TEAM_RUN_ID:-team}"; title="[$run] $subject"
  mkdir -p "$(_nt_dir)" 2>/dev/null || true
  key="$(_nt_key "$subject")"
  if [ "$class" = action ] && ! _nt_action_allowed; then
    # Deny by default when an allowlist is set: the sender is not on it, so this
    # lands in the digest. The log line keeps the original intent visible.
    _nt_locked digest _nt_digest_add "$(_nt_ts) $subject :: $body"
    _nt_log "DEMOTED action->info [${NOTIFY_SOURCE:-unknown}] $subject :: $body"
    return 0
  fi
  case "$class" in
    page)
      st="$(_nt_dir)/page.$key"; last="$(_nt_read "$st")"
      if [ $((now - last)) -lt "${NOTIFY_PAGE_REPEAT_SEC:-1800}" ]; then _nt_log "DEDUPE page $subject :: $body"; return 0; fi
      notify_muted && title="[maintenance] $title"
      # THE STAMP GOES AFTER THE PUSH. It used to go before, so a push that never arrived
      # still opened the repeat window and silenced every retry inside it. A page is the
      # loudest class there is; latching it on a failure is the worst place for this to live.
      if _nt_push 5 "$title" "$body" "${tags:-rotating_light}"; then
        printf '%s' "$now" > "$st"
        _nt_log "SENT page 5 $subject :: $body"
      else
        _nt_log "LOG-ONLY page $subject :: $body (NOT delivered; repeat window not started, the next attempt retries)"
      fi ;;
    action)
      if notify_muted; then _nt_log "MUTED action $subject :: $body"; return 0; fi
      st="$(_nt_dir)/action.$key"; last="$(_nt_read "$st")"
      if [ $((now - last)) -lt "${NOTIFY_ACTION_COOLDOWN_SEC:-21600}" ]; then _nt_log "DEDUPE action $subject :: $body"; return 0; fi
      if ! _nt_in_hours; then
        # QUEUED STILL STAMPS, on purpose: the message is RETAINED and notify_flush delivers
        # it, so suppressing repeats while it waits is right. Otherwise an overnight outage
        # fills the queue with one line per check.
        printf '%s' "$now" > "$st"
        _nt_locked queue _nt_enqueue "$subject" "$body"; return 0
      fi
      # Same reason as the page branch: a failed push must not open the cooldown. Measured
      # on a real outage: the first push failed, the stamp was already written, and the five
      # retries over the next hour all logged DEDUPE while the service stayed down.
      if _nt_push 4 "$title" "$body" "${tags:-warning}"; then
        printf '%s' "$now" > "$st"
        _nt_log "SENT action 4 $subject :: $body"
      else
        _nt_log "LOG-ONLY action $subject :: $body (NOT delivered; cooldown not started, the next attempt retries)"
      fi ;;
    info)
      _nt_locked digest _nt_digest_add "$(_nt_ts) $subject :: $body"
      _nt_log "DIGEST info $subject :: $body" ;;
    *) _nt_log "BAD-CLASS $class $subject :: $body"; return 2 ;;
  esac
}

# NOTHING CALLS notify_resolved: no sender in this repository reports a recovery, so no
# "resolved" push is ever sent and a page simply stops repeating once its sender stops calling.
# Kept, with _nt_unqueue, because bin/tests/notify.test.sh covers both and a sender may use it.
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
  _nt_unqueue "$subject"
}

# Queue and digest writers. Every one runs under _nt_locked (queue.lock or digest.lock), and every
# rewrite goes through a temp file plus mv, so a reader never sees a half-written file. The temp
# name is fixed: only the lock holder writes it, and a leftover is overwritten by the next rewrite.
_nt_enqueue() {
  printf '%s\t%s\t%s\n' "$(_nt_ts)" "$1" "$2" >> "$(_nt_dir)/queue"
  _nt_log "QUEUED action $1 :: $2 [queue now $(_nt_qlen)]"
}

# _nt_digest_add <line>: append one info line; past NOTIFY_DIGEST_MAX_LINES drop the oldest down
# to 90% of the cap (one rewrite per tenth of the cap, not one per append) and log the count.
_nt_digest_add() {
  local d tmp max="${NOTIFY_DIGEST_MAX_LINES:-1000}" n keep
  d="$(_nt_dir)/digest"; tmp="$d.tmp"
  printf '%s\n' "$1" >> "$d"
  case "$max" in ''|*[!0-9]*|0) return 0 ;; esac
  n=$(wc -l < "$d")
  [ "$n" -gt "$max" ] || return 0
  keep=$(( max * 9 / 10 )); [ "$keep" -ge 1 ] || keep=1
  if tail -n "$keep" "$d" > "$tmp" && mv -f "$tmp" "$d"; then
    _nt_log "DIGEST-TRIMMED $((n - keep)) oldest info line(s) dropped, cap NOTIFY_DIGEST_MAX_LINES=$max [digest now $keep]"
  fi
}

# A queued out-of-hours action whose condition has resolved must not reach the morning flush.
# Queue lines are "ts<TAB>subject<TAB>body"; keep every line whose subject differs. The subject
# goes through ENVIRON, not awk -v, which would expand backslash escapes and miss the match.
_nt_unqueue() { _nt_locked queue _nt_unqueue_locked "$@"; }
_nt_unqueue_locked() {
  local subject="$1" q tmp n
  q="$(_nt_dir)/queue"; tmp="$q.tmp"
  n=0; [ -s "$q" ] && n=$(S="$subject" awk -F'\t' '$2==ENVIRON["S"]' "$q" | wc -l)
  if [ "$n" -eq 0 ]; then _nt_log "UNQUEUE-NOMATCH 0 queued action(s) $subject [queue now $(_nt_qlen)]"; return 0; fi
  if S="$subject" awk -F'\t' '$2!=ENVIRON["S"]' "$q" > "$tmp" && mv -f "$tmp" "$q"; then
    _nt_log "UNQUEUED $n queued action(s) $subject [queue now $(_nt_qlen)]"
  else
    _nt_log "UNQUEUE-FAILED $n queued action(s) $subject [queue now $(_nt_qlen)]"
  fi
}

notify_flush() {
  [ -s "$(_nt_dir)/queue" ] || return 0
  _nt_in_hours || return 0
  _nt_locked queue _nt_flush_locked
}

# Under the lock: re-read (a concurrent flush may have emptied the queue) and drop only the n lines
# that were pushed.
_nt_flush_locked() {
  local q tmp n body
  q="$(_nt_dir)/queue"; tmp="$q.tmp"
  [ -s "$q" ] || return 0
  n=$(wc -l < "$q"); body="$(head -n "$n" "$q" | cut -f2- | tr '\t' ':' | head -c 3800)"
  if _nt_push 4 "[${TEAM_RUN_ID:-team}] $n action(s) queued out of hours" "$body" "warning"; then
    { tail -n +"$((n + 1))" "$q" > "$tmp" && mv -f "$tmp" "$q"; } || : > "$q"
    _nt_log "FLUSHED $n queued actions [queue now $(_nt_qlen)]"
  else
    _nt_log "FLUSH-FAILED $n queued actions [queue now $(_nt_qlen)]"
  fi
}

notify_digest() {
  notify_flush
  [ -s "$(_nt_dir)/digest" ] || { _nt_log "DIGEST-EMPTY"; return 0; }
  _nt_locked digest _nt_digest_locked
}

_nt_digest_locked() {
  local d="$(_nt_dir)/digest" n body
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

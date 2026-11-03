#!/usr/bin/env bash
# compaction-clear-rebrief-pending.test.sh: compaction-watchdog's orchestrator recovery.
# - A recovery ALWAYS sends /clear: it runs only at the ceiling, so the context is full again.
# - If /clear went in and the rebrief did not, the marker records the session the /clear started. The main loop then
#   retries the rebrief only while the pane is still in that session with no prompt typed since.
# - Another session, a typed prompt or an hour's age drops the marker unsent: somebody else dealt with the pane.
# - The retry fails closed: a marker with no session is dropped; an unreadable pane
#   session, a busy pane or typed text on the input line waits; a pane with no box is never typed into blind.
# - A drop that leaves the pane unbriefed (the hour, no session) and a wait past 10 minutes
#   are told to the orchestrator on the bus, the wait once; a drop because somebody else dealt with the pane is not.
# Stubs replace tmux, ti_send and pane_session: no tmux server, no pane. SRC=<engine tree> sources that tree's watchdog
# (the red check).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
export NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/health"
fail=0; n=0
ok()  { n=$((n+1)); echo "  ok   $1"; }
bad() { n=$((n+1)); fail=1; echo "  FAIL $1"; }
P="$TD/health/clear-rebrief-pending"
TOLD="$TD/told"
J="$TD/session.jsonl"

IDLE=$'────────\n\e[39m❯\xc2\xa0\n────────\n  -- INSERT --'
SCREEN="$IDLE"
run() { # run <function> <rc for the rebrief send> <session id the pane is in, "" = unreadable>: prints the sends, then RC=<rc>
  env -u COMPACT_PRESERVE SCREEN="$SCREEN" COMPACT_BUS_SINK="${SINK-$TOLD}" COMPACT_BUS_SEND="$TD/fake-sender" COMPACT_TEST_SOURCE=1 TEAM_DIR="$TD" TEAM_RUN_ID=testrun COMPACT_SOCKET=no-such-socket COMPACT_SESSION=s \
    COMPACT_LOCK="$TD/lock" COMPACT_PIDFILE="$TD/pid" COMPACT_LOG="$TD/log" COMPACT_HEALTH_DIR="$TD/health" \
    FN="$1" REBRIEF_RC="$2" PANE_SID="$3" PANE_JSONL="$J" bash -c '
      . "$0/bin/compaction-watchdog.sh"
      sleep() { :; }
      tmux_o() { case "$1" in capture-pane) printf "%s\n" "$SCREEN" ;; send-keys) echo "BLIND $*" ;; esac; }
      pane_session() { [ -n "$PANE_SID" ] || return 1; printf "%s %s\n" "$PANE_SID" "$PANE_JSONL"; }
      ti_send() { case "$2" in /clear) echo "SEND /clear"; return 0 ;; *) echo "SEND rebrief"; return "$REBRIEF_RC" ;; esac; }
      "$FN" t:0; echo "RC=$?"' "$SRC" 2>/dev/null
}
# The head of a real transcript right after /clear (claude 2.1.312): a caveat entry, then the command.
cmd_only() {
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request</local-command-caveat>"}}' \
    '{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}' > "$J"
}

cmd_only
out="$(run do_clear_rebrief 1 S1)"
[ "$(grep -c 'SEND /clear' <<<"$out")" = 1 ] && [ "$(grep -c 'SEND rebrief' <<<"$out")" = 3 ] && grep -q 'RC=1' <<<"$out" \
  && ok "rebrief fails: /clear once, rebrief tried 3 times, exit 1" || bad "first recovery :: $(tr '\n' ' ' <<<"$out")"
grep -qx 'sid=S1' "$P" 2>/dev/null && ok "pending marker records the session the /clear started" || bad "marker :: $(cat "$P" 2>/dev/null)"

out="$(run do_clear_rebrief 1 S1)"
grep -q 'SEND /clear' <<<"$out" && ok "a later wedge still gets /clear (the marker never skips it)" || bad "later wedge skipped /clear :: $out"

out="$(run pending_rebrief 0 S1)"
! grep -q 'SEND /clear' <<<"$out" && [ "$(grep -c 'SEND rebrief' <<<"$out")" = 1 ] && [ ! -f "$P" ] \
  && ok "same session, no prompt typed: the main loop sends the rebrief only, marker removed" || bad "pending same session :: $out"

run do_clear_rebrief 1 S1 >/dev/null
out="$(run pending_rebrief 0 S2)"
! grep -q 'SEND' <<<"$out" && [ ! -f "$P" ] && ok "pane in another session: dropped, nothing sent" || bad "other session :: $out"

run do_clear_rebrief 1 S1 >/dev/null
printf '%s\n' '{"type":"user","message":{"role":"user","content":"You are the orchestrator, rebriefed by hand"}}' >> "$J"
out="$(run pending_rebrief 0 S1)"
! grep -q 'SEND' <<<"$out" && [ ! -f "$P" ] && ok "a prompt typed since the /clear: dropped, nothing sent" || bad "typed prompt :: $out"

cmd_only; run do_clear_rebrief 1 S1 >/dev/null
sed -i "s/^at=.*/at=$(( $(date +%s) - 7200 ))/" "$P"
out="$(run pending_rebrief 0 S1)"
! grep -q 'SEND' <<<"$out" && [ ! -f "$P" ] && ok "an hour-old marker: dropped, nothing sent" || bad "stale marker :: $out"

pend() { cmd_only; run do_clear_rebrief 1 S1 >/dev/null; }
kept() { [ -f "$P" ] && ! grep -q 'SEND' <<<"$1"; }

pend; printf 'sid=unknown\nat=%s\n' "$(date +%s)" > "$P"
out="$(run pending_rebrief 0 S1)"
! grep -q 'SEND' <<<"$out" && [ ! -f "$P" ] && ok "a marker whose session was never read: dropped, nothing sent" || bad "unknown sid :: $out"

pend; out="$(run pending_rebrief 0 "")"
kept "$out" && ok "pane session unreadable now: waits, marker kept, nothing sent" || bad "unreadable session :: $out"

pend; SCREEN=$'some output\n✻ Working… (esc to interrupt)\n'"$IDLE"; out="$(run pending_rebrief 0 S1)"; SCREEN="$IDLE"
kept "$out" && ok "pane busy: waits, marker kept, nothing sent" || bad "busy pane :: $out"

pend; SCREEN=$'────────\n\e[39m❯\xc2\xa0half typed by hand\n────────\n  -- INSERT --'; out="$(run pending_rebrief 0 S1)"; SCREEN="$IDLE"
kept "$out" && ok "real text on the input line: waits, marker kept, nothing sent" || bad "real input :: $out"

pend; out="$(run pending_rebrief 2 S1)"
[ -f "$P" ] && ! grep -q 'BLIND' <<<"$out" && ok "no box (ti_send rc 2): the retry never types blind, marker kept" || bad "blind retry :: $out"

age() { sed -i "s/^at=.*/at=$(( $(date +%s) - $1 ))/" "$P"; }
told() { [ -f "$TOLD" ] && wc -l < "$TOLD" || echo 0; }

: > "$TOLD"; pend; age 7200; run pending_rebrief 0 S1 >/dev/null
[ "$(told)" = 1 ] && grep -q 'over an hour ago' "$TOLD" && ok "dropped after the hour: the orchestrator is told" || bad "hour drop not told :: $(cat "$TOLD")"

: > "$TOLD"; pend; printf 'sid=unknown\nat=%s\n' "$(date +%s)" > "$P"; run pending_rebrief 0 S1 >/dev/null
[ "$(told)" = 1 ] && ok "dropped because the session was never read: the orchestrator is told" || bad "unknown sid not told :: $(cat "$TOLD")"

: > "$TOLD"; pend; run pending_rebrief 0 S2 >/dev/null
[ "$(told)" = 0 ] && ok "dropped because the pane is in another session: nobody told (somebody dealt with it)" || bad "other session told :: $(cat "$TOLD")"

: > "$TOLD"; pend; age 300; SCREEN=$'✻ Working… (esc to interrupt)\n'"$IDLE"; run pending_rebrief 0 S1 >/dev/null
[ "$(told)" = 0 ] && ok "a wait at 5 minutes: not told yet" || bad "early wait told :: $(cat "$TOLD")"
age 660; run pending_rebrief 0 S1 >/dev/null; run pending_rebrief 0 S1 >/dev/null; SCREEN="$IDLE"
[ "$(told)" = 1 ] && grep -q 'over 10 minutes ago' "$TOLD" && [ -f "$P" ] \
  && ok "a wait past 10 minutes: told once over two cycles, marker kept" || bad "long wait :: $(told) :: $(cat "$TOLD")"

: > "$TOLD"; pend; age 660; run pending_rebrief 1 S1 >/dev/null
[ "$(told)" = 1 ] && ok "a retry not seen submitted past 10 minutes: told" || bad "failed retry not told :: $(cat "$TOLD")"

# Without a sink a real send needs a live team ($TEAM_DIR/state.md), so a suite cannot put the notice on the live bus.
# The fake sender is not named bus-send.py, which the push gate's python3 shim diverts.
printf '#!/usr/bin/env python3\nimport sys\nopen(sys.argv[0] + ".calls", "a").write(" ".join(sys.argv[1:]) + "\\n")\n' > "$TD/fake-sender"
pend; age 7200; SINK="" run pending_rebrief 0 S1 >/dev/null
[ ! -f "$TD/fake-sender.calls" ] && ok "no sink, no state.md (not a live team): the notice is not sent" || bad "sent without a live team :: $(cat "$TD/fake-sender.calls")"
: > "$TD/state.md"; pend; age 7200; SINK="" run pending_rebrief 0 S1 >/dev/null; rm -f "$TD/state.md"
grep -q -- '--to orchestrator' "$TD/fake-sender.calls" 2>/dev/null && ok "no sink, live team: sent with bus-send's arguments to the orchestrator" || bad "live-team send :: $(cat "$TD/fake-sender.calls" 2>/dev/null)"

hook="$(grep -A1 'if \[ "$orchflag" = 1 \] && \[ -f "$CLEAR_PENDING" \]; then' "$SRC/bin/compaction-watchdog.sh")"
grep -q 'pending_rebrief "$target"' <<<"$hook" \
  && ok "the main loop calls pending_rebrief for the orchestrator while a marker exists" || bad "main loop does not call pending_rebrief"

[ "$fail" = 0 ] && echo "compaction-clear-rebrief-pending.test: PASS ($n)" || { echo "compaction-clear-rebrief-pending.test: FAIL"; exit 1; }

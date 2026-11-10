#!/usr/bin/env bash
# Stop hook: a team role may not end its turn with its bus reader unarmed.
#
# Seen in a real run: the orchestrator's `bus-inbox.py wait` returned at once (a message was already queued);
# its completion was folded into the RUNNING turn, so no new turn began and the "read it AND re-arm" rule had
# no boundary to fire on. The turn ended with reader=none and the listener alive, so `status` exited 0 and
# nothing complained: 32 lines piled up for almost two hours. Only the harness sees the turn end, so the
# check lives here.
#
# Verdicts (stdout JSON is read by Claude Code; exit is always 0):
#   listener alive, reader=none  -> block: arm the reader
#   listener dead (status rc 2)  -> block: start the listener, then arm the reader
#   reader armed / not a role    -> allow
#   listener dead, marker present -> allow: a deliberate disconnect (below)
# DELIBERATE DISCONNECT. docs/BUS-INBOX.md lets a role disconnect (`/is d`) when the orchestrator says so,
# and the dead listener that follows is expected. The role marks it, after the disconnect, with
#   touch "${BUS_INBOX_DIR:-$TEAM_DIR/bus-inbox}/<name>.disconnected"
# While that file exists and the listener is dead, every turn end is allowed (a marker honoured once
# would block the next turn end and ask for the restart the orchestrator ruled out). The first time this
# hook sees the role's listener alive again, it renames the marker to <name>.disconnected.cleared, so a
# later accidental death is blocked as usual. `bus-inbox.py start <name>` removes the marker on entry:
# a reconnect whose start fails, or a new role added under a retired role's name, must not inherit it
# (the old .pid and .log files still let the window fallback name the role, so the dead listener would
# otherwise be allowed at every turn end).
# Never blocks twice in a row (stop_hook_active). FAIL OPEN: a status call that hangs past
# STOP_BUS_READER_TIMEOUT (5 s) or errors is logged and allowed; a broken hook must never wedge a role.
# Race, on purpose: a background wait armed this turn that has ALREADY returned holds no reader lock, so it
# counts as unarmed. That is exactly the case above.
#
# Which role is this session? 1) the pump whose argv is `_pump <role> <cc-pid>` for this session's Claude Code
# pid (stable across /clear); 2) if no pump matches, the tmux window name, under the FALLBACK rules below.
# Neither -> not a team role -> allow.
# A human `!` command in a role's pane also ends a turn, so it is checked too (the block asks the role to arm
# its reader, which is right whoever ended the turn).
# Seams (tests only): STOP_BUS_READER_CC_PID, STOP_BUS_READER_BUS_INBOX (path to bus-inbox.py),
# STOP_BUS_READER_TIMEOUT, STOP_BUS_READER_LOG; BUS_INBOX_DIR is honoured as bus-inbox.py honours it.
input="$(cat 2>/dev/null)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
BI="${STOP_BUS_READER_BUS_INBOX:-$here/bin/bus-inbox.py}"
[ -n "${TEAM_DIR:-}" ] || exit 0
INBOX="${BUS_INBOX_DIR:-$TEAM_DIR/bus-inbox}"
[ -d "$INBOX" ] || exit 0
LOG="${STOP_BUS_READER_LOG:-$TEAM_DIR/audit/stop-bus-reader.log}"
TMO="${STOP_BUS_READER_TIMEOUT:-5}"; case "$TMO" in ''|*[!0-9]*) TMO=5 ;; esac
# Capped: past STOP_BUS_READER_LOG_MAX bytes (1 MB) the log moves to .1, replacing the previous one.
LOG_MAX="${STOP_BUS_READER_LOG_MAX:-1048576}"; case "$LOG_MAX" in ''|*[!0-9]*) LOG_MAX=1048576 ;; esac
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null
  [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -ge "$LOG_MAX" ] && mv -f -- "$LOG" "$LOG.1" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; }

# claude_at_or_above <pid>: the nearest claude process at or above <pid> (bus-inbox.py _cc_pid's rule), else -1
claude_at_or_above() {
  local pid=$1 exe rest i=0
  while [ "$pid" -gt 1 ] 2>/dev/null && [ $i -lt 64 ]; do
    i=$((i+1))
    exe="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | head -1)"; exe="${exe##*/}"; exe="${exe,,}"
    rest="$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" | cut -d' ' -f2-)"; rest="${rest,,}"
    case "$exe" in claude|claude-*) echo "$pid"; return ;; esac
    case "$exe" in node|node.exe) case "$rest" in */claude*|*claude-code*|*/.claude/*) echo "$pid"; return ;; esac ;; esac
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"; [ -n "$pid" ] || break
  done
  echo -1
}
role=""; via=""
cc="${STOP_BUS_READER_CC_PID:-$(claude_at_or_above "$PPID")}"
if [ "$cc" != -1 ]; then
  for pf in "$INBOX"/*.pid; do
    [ -f "$pf" ] || continue
    read -r pump _ < "$pf" 2>/dev/null || continue
    case "$pump" in ''|*[!0-9]*) continue ;; esac
    mapfile -t a < <(tr '\0' '\n' 2>/dev/null < "/proc/$pump/cmdline")
    for i in "${!a[@]}"; do
      if [ "${a[$i]}" = _pump ] && [ "${a[$((i+2))]:-}" = "$cc" ]; then role="${a[$((i+1))]:-}"; via=pump; break 2; fi
    done
  done
fi
# FALLBACK, for a role whose listener is dead (no pump left to name it). Any OTHER claude
# in a role's window -- a `claude -p` the role runs (bin/gates/llm-judge.sh, observer.sh), or a second pane --
# was named as the role, told to arm the role's reader (it would consume the role's messages), and a print-mode
# caller's stdout gained a second answer. So the window names the role only for the role's OWN claude: not in
# print mode, not nested under another claude, in the window's FIRST pane; and only when the role's listener is
# DEAD (a live listener belongs to another claude, so this session is not that role).
if [ -z "$role" ] && [ "$cc" != -1 ] && [ -n "${TMUX_PANE:-}" ] && [ -n "${TEAM_SESSION:-}" ]; then
  ccargs=" $(tr '\0' ' ' 2>/dev/null < "/proc/$cc/cmdline") "
  parent="$(awk '{print $4}' "/proc/$cc/stat" 2>/dev/null)"
  case "$ccargs" in *" -p "*|*" --print "*|*" --print="*) exit 0 ;; esac
  [ "$(claude_at_or_above "${parent:-1}")" = -1 ] || exit 0
  sw="$(timeout 2 tmux display -p -t "$TMUX_PANE" '#{session_name} #{window_name}' 2>/dev/null)"
  first="$(timeout 2 tmux list-panes -t "$TMUX_PANE" -F '#{pane_index} #{pane_id}' 2>/dev/null | sort -n | head -1)"
  if [ "${sw%% *}" = "$TEAM_SESSION" ] && [ "${first#* }" = "$TMUX_PANE" ]; then
    w="${sw#* }"; { [ -f "$INBOX/$w.pid" ] || [ -f "$INBOX/$w.log" ]; } && { role="$w"; via=window; }
  fi
fi
[ -n "$role" ] || exit 0
case "$role" in *[!A-Za-z0-9-]*) log "role name '$role' not a bus name: allowed"; exit 0 ;; esac

if [ "$(printf '%s' "$input" | python3 -c 'import json,sys
try: print("1" if json.loads(sys.stdin.read() or "{}").get("stop_hook_active") else "0")
except Exception: print("0")' 2>/dev/null)" = 1 ]; then
  log "$role stop_hook_active: allowed (never block twice in a row)"; exit 0
fi

out="$(timeout "$TMO" python3 "$BI" status "$role" 2>&1)"; rc=$?
mark="$INBOX/$role.disconnected"
if [ -f "$mark" ]; then
  case "$rc" in
    0) mv -f -- "$mark" "$mark.cleared" 2>/dev/null && log "$role listener alive again: disconnect marker cleared" ;;
    2) log "$role listener dead after a deliberate disconnect (marker): allowed"; exit 0 ;;
  esac
fi
if [ "$via" = window ] && [ "$rc" = 0 ]; then
  log "$role named by window only, but its listener is alive (another claude owns it): allowed"; exit 0
fi
q="$(printf '%q' "$here/bin/bus-inbox.py")"
arm="python3 $q wait $role 7200"
block() { python3 -c 'import json,sys; print(json.dumps({"decision": "block", "reason": sys.argv[1]}))' "$1"; }
case "$rc" in
  0)
    case "$out" in
      *"reader=armed"*) exit 0 ;;
      *"reader=none"*) log "$role BLOCK reader=none ($out)"
        block "bus reader is not armed: run $arm with run_in_background before ending the turn"; exit 0 ;;
    esac ;;
  2) log "$role BLOCK listener dead ($out)"
     block "bus listener is DEAD: run python3 $q start $role, then $arm with run_in_background, and send a status: line to the orchestrator"; exit 0 ;;
  124) log "$role status timed out after ${TMO}s: allowed (fail open)"; exit 0 ;;
esac
log "$role status rc=$rc unparsed: allowed (fail open): $(printf '%s' "$out" | head -c 200)"
exit 0

#!/usr/bin/env bash
# team-status.sh: one-glance dashboard for the team. Reads .team/active (roles
# the launcher spawned) for liveness, tmux for window + idle time, and the /is
# messages.log for each role's last message. No bus auth needed, so it runs from
# anywhere (the orchestrator can also run /is list for the live bus roster).
#
# Usage: bin/team-status.sh           # wide desktop output
#        bin/team-status.sh --mobile  # compact ~40-col output for a phone

set -uo pipefail

mobile=0
for a in "$@"; do case "$a" in
  --mobile|-m) mobile=1 ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
esac; done

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
active="$TEAM_DIR/active"
msglog="$HOME/.claude/data/inter-session/messages.log"

if [ "$mobile" = 1 ]; then
  echo "team $TEAM_SESSION  port $TEAM_PORT"
else
  echo "team: $TEAM_SESSION   bus port: $TEAM_PORT"
fi
if [ ! -f "$active" ] || [ ! -s "$active" ]; then
  echo "no roles recorded (.team/active empty). Launch with bin/launch-team.sh."
  exit 0
fi

fmt_age() {  # epoch -> compact age
  local now d; now="$(date +%s)"; d=$((now - $1))
  if   [ "$d" -lt 60 ];   then echo "${d}s"
  elif [ "$d" -lt 3600 ]; then echo "$((d/60))m"
  else echo "$((d/3600))h"; fi
}

last_msg() {  # role -> "kind: text snippet (age)"
  [ -f "$msglog" ] || { echo "-"; return; }
  python3 - "$1" "$msglog" <<'PY' 2>/dev/null || echo "-"
import sys, json, datetime, time
role, logf = sys.argv[1], sys.argv[2]
last = None
for line in open(logf, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("from_name") == role:
        last = d
if not last:
    print("-"); sys.exit()
text = " ".join((last.get("text") or "").split())[:46]
age = ""
try:
    t = datetime.datetime.fromisoformat(last["ts"])
    secs = int(time.time() - t.timestamp())
    age = f" ({secs}s)" if secs < 60 else f" ({secs//60}m)" if secs < 3600 else f" ({secs//3600}h)"
except Exception:
    pass
print(f"{text}{age}")
PY
}

health_of() {  # role -> short health state (from api-watchdog), or "-"
  local hf="$TEAM_DIR/health/$1.json"
  [ -f "$hf" ] || { echo "-"; return; }
  local s r; s="$(jq -r '.state // "-"' "$hf" 2>/dev/null)"; r="$(jq -r '.retries // 0' "$hf" 2>/dev/null)"
  case "$s" in
    active)      echo "ok" ;;
    stalled-api) echo "STALL/${r}" ;;
    give-up)     echo "GIVE-UP" ;;
    *)           echo "$s" ;;
  esac
}

if [ "$mobile" = 1 ]; then
  # 40-col compact: role | live | idle | health (drop pid/window/last-msg).
  printf '%-12s %-3s %-5s %s\n' ROLE A IDLE HEALTH
  while IFS=$'\t' read -r pid wid role; do
    [ -n "${role:-}" ] || continue
    if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
      alive=y; else alive=X; fi
    idle="-"
    if [ -n "${wid:-}" ] && act="$(tmux display-message -p -t "$wid" '#{window_activity}' 2>/dev/null)" && [ -n "$act" ]; then
      idle="$(fmt_age "$act")"
    fi
    printf '%-12s %-3s %-5s %s\n' "${role:0:12}" "$alive" "$idle" "$(health_of "$role")"
  done < "$active"
  exit 0
fi

printf '%-14s %-8s %-6s %-8s %-7s %-9s %s\n' ROLE PID ALIVE WINDOW IDLE HEALTH LAST
while IFS=$'\t' read -r pid wid role; do
  [ -n "${role:-}" ] || continue
  if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
    alive=yes; else alive=NO; fi
  win="-"; idle="-"
  if [ -n "${wid:-}" ] && act="$(tmux display-message -p -t "$wid" '#{window_activity}' 2>/dev/null)" && [ -n "$act" ]; then
    win="$wid"; idle="$(fmt_age "$act")"
  fi
  printf '%-14s %-8s %-6s %-8s %-7s %-9s %s\n' "$role" "$pid" "$alive" "$win" "$idle" "$(health_of "$role")" "$(last_msg "$role")"
done < "$active"

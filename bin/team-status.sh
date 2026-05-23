#!/usr/bin/env bash
# team-status.sh: one-glance dashboard for the team. Reads .team/active (roles
# the launcher spawned) for liveness, tmux for window + idle time, and the /is
# messages.log for each role's last message. No bus auth needed, so it runs from
# anywhere (the orchestrator can also run /is list for the live bus roster).
#
# Usage: bin/team-status.sh

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
active="$repo/.team/active"
msglog="$HOME/.claude/data/inter-session/messages.log"

echo "team: $TEAM_SESSION   bus port: $TEAM_PORT"
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

printf '%-14s %-8s %-6s %-8s %-7s %s\n' ROLE PID ALIVE WINDOW IDLE LAST
while IFS=$'\t' read -r pid wid role; do
  [ -n "${role:-}" ] || continue
  if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[c]laude'; then
    alive=yes; else alive=NO; fi
  win="-"; idle="-"
  if [ -n "${wid:-}" ] && act="$(tmux display-message -p -t "$wid" '#{window_activity}' 2>/dev/null)" && [ -n "$act" ]; then
    win="$wid"; idle="$(fmt_age "$act")"
  fi
  printf '%-14s %-8s %-6s %-8s %-7s %s\n' "$role" "$pid" "$alive" "$win" "$idle" "$(last_msg "$role")"
done < "$active"

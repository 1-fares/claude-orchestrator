#!/usr/bin/env bash
# team-logs.sh: durable, greppable per-role history from the /is messages.log
# (the bus already persists every message). The log is the source of truth;
# --sync materializes per-role files under .team/log/ for offline grepping.
#
# Usage:
#   bin/team-logs.sh                 # last 40 messages among this team's roles
#   bin/team-logs.sh <role> [n]      # last n (default 40) for one role
#   bin/team-logs.sh --sync          # write .team/log/<role>.log per team role

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
active="$TEAM_DIR/active"
msglog="$HOME/.claude/data/inter-session/messages.log"
[ -f "$msglog" ] || { echo "no messages.log yet" >&2; exit 0; }

roles_of_team() { [ -f "$active" ] && cut -f3 "$active" | sort -u; }

render() {  # filter-role(or empty=all team) limit
  python3 - "$msglog" "$1" "$2" "$(roles_of_team | paste -sd, -)" <<'PY'
import sys, json
logf, role, limit, team = sys.argv[1], sys.argv[2], int(sys.argv[3] or 40), sys.argv[4]
teamset = set(t for t in team.split(",") if t)
rows = []
for line in open(logf, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    frm, to = d.get("from_name"), d.get("to")
    if role:
        if frm != role and to != role:
            continue
    elif teamset and frm not in teamset and to not in teamset:
        continue
    ts = (d.get("ts") or "")[11:19]
    text = " ".join((d.get("text") or "").split())
    rows.append(f"{ts} {frm or '?'} -> {to or 'all'}: {text}")
for r in rows[-limit:]:
    print(r)
PY
}

case "${1:-}" in
  --sync)
    mkdir -p "$TEAM_DIR/log"
    for r in $(roles_of_team); do render "$r" 100000 > "$TEAM_DIR/log/$r.log"; echo "wrote .team/log/$r.log"; done
    ;;
  "") render "" 40 ;;
  *)  render "$1" "${2:-40}" ;;
esac

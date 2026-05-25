#!/usr/bin/env bash
# inbox.sh: list every live orchestrator run on this clone, with its run-id, age,
# the last thing the orchestrator said over /is (preview), and the attach + approve
# commands. Built for the phone-arrives-with-an-ntfy-push case: one screen tells
# you which run is asking for what, with the literal commands to paste.
#
# A run is "live" if a tmux session exists on -L orchestrator AND .team-<run-id>/
# (or .team/) records active roles. Older runs without state are listed too if
# their tmux session is still alive.
#
# Usage:
#   bin/inbox.sh            # short table
#   bin/inbox.sh --long     # include role roster per run
#   bin/inbox.sh --json     # machine-readable

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
msglog="$HOME/.claude/data/inter-session/messages.log"

long=0; want_json=0
for a in "$@"; do case "$a" in
  --long|-l) long=1 ;;
  --json|-j) want_json=1 ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

# Find every team session on this socket (orch-*).
mapfile -t sessions < <(tmux -L orchestrator list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^orch-' || true)
if [ "${#sessions[@]}" -eq 0 ]; then
  echo "no live orchestrator sessions on socket '$TEAM_TMUX'."
  echo "(check 'tmux -L orchestrator ls' or 'bin/team-status.sh')"
  exit 0
fi

# For each session, try to recover its TEAM_RUN_ID and state dir by scanning the
# clone's .team-*/ dirs and matching session names. team-env's hash is
# deterministic, so we can reverse the lookup by trial.
declare -A rid_of=()
for d in "$repo"/.team-* "$repo"/.team; do
  [ -d "$d" ] || continue
  rid="${d##*/.team-}"; [ "$rid" = ".team" ] && rid="(legacy)"
  # Re-derive the session name with this rid to confirm.
  if [ "$rid" = "(legacy)" ]; then sess="$TEAM_SESSION_DEFAULT_NA"; fi
  if [ "$rid" != "(legacy)" ]; then
    h="$(printf '%s\0%s' "$TEAM_REPO" "$rid" | cksum | cut -d' ' -f1)"
    sess="orch-${h: -5}"
  else
    h="$(printf '%s' "$TEAM_REPO" | cksum | cut -d' ' -f1)"
    sess="orch-${h: -5}"
  fi
  rid_of["$sess"]="$rid"
done

# Last /is message from the orchestrator of a given run, with kind + snippet.
last_orchestrator_msg() {
  local rid="$1"
  [ -f "$msglog" ] || { echo "-"; return; }
  python3 - "$msglog" <<'PY' 2>/dev/null || echo "-"
import sys, json, datetime, time
logf = sys.argv[1]
last = None
for line in open(logf, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("from_name") == "orchestrator":
        last = d
if not last:
    print("-"); sys.exit()
text = " ".join((last.get("text") or "").split())[:60]
age = ""
try:
    t = datetime.datetime.fromisoformat(last["ts"])
    s = int(time.time() - t.timestamp())
    age = f" ({s}s)" if s < 60 else f" ({s//60}m)" if s < 3600 else f" ({s//3600}h)"
except Exception: pass
print(f"{text}{age}")
PY
}

if [ "$want_json" = 1 ]; then
  echo -n '['; first=1
  for s in "${sessions[@]}"; do
    rid="${rid_of[$s]:-?}"
    age="$(tmux -L orchestrator display-message -p -t "$s" '#{session_created}' 2>/dev/null)"
    msg="$(last_orchestrator_msg "$rid" | tr -d '"')"
    [ "$first" = 1 ] || echo -n ','; first=0
    printf '{"session":"%s","run_id":"%s","created":%s,"last_orchestrator":"%s"}' "$s" "$rid" "${age:-0}" "$msg"
  done
  echo ']'
  exit 0
fi

# Human-readable table.
echo "live orchestrator runs on socket '$TEAM_TMUX' (clone: $TEAM_REPO):"
echo
printf '%-13s %-22s %-7s %s\n' SESSION RUN-ID AGE LAST-FROM-ORCH
now=$(date +%s)
for s in "${sessions[@]}"; do
  rid="${rid_of[$s]:-?}"
  created="$(tmux -L orchestrator display-message -p -t "$s" '#{session_created}' 2>/dev/null)"
  if [ -n "$created" ]; then
    d=$((now - created))
    if [ "$d" -lt 60 ]; then age="${d}s"
    elif [ "$d" -lt 3600 ]; then age="$((d/60))m"
    else age="$((d/3600))h"; fi
  else age="-"; fi
  msg="$(last_orchestrator_msg "$rid")"
  printf '%-13s %-22s %-7s %s\n' "$s" "${rid:0:22}" "$age" "${msg:0:50}"
  if [ "$long" = 1 ] && [ -f "$repo/.team-$rid/active" ]; then
    awk -F'\t' '{printf "                roles: "} { printf "%s ", $3 } END { print "" }' "$repo/.team-$rid/active"
  fi
done

echo
echo "to enter a run:    TEAM_RUN_ID=<run-id> $repo/bin/attach.sh"
echo "to approve a run:  TEAM_RUN_ID=<run-id> $repo/bin/approve.sh    # sends 'go'"
echo "to inject text:    TEAM_RUN_ID=<run-id> $repo/bin/approve.sh '<text>'"

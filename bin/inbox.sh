#!/usr/bin/env bash
# inbox.sh: list every live orchestrator run on this clone, with its run-id, age,
# the last thing the orchestrator said over /is (preview), and the attach + approve
# commands. Built for the phone-arrives-with-an-ntfy-push case: one screen tells
# you which run is asking for what, with the literal commands to paste.
#
# A run is "live" if a tmux session exists on the team socket ($TEAM_TMUX, default
# 'orchestrator') AND .team-<run-id>/ (or .team/) records active roles. Older runs
# without state are listed too if their tmux session is still alive.
#
# Usage:
#   bin/inbox.sh            # short table
#   bin/inbox.sh --long     # include role roster per run
#   bin/inbox.sh --json     # machine-readable

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
isdata="${INTER_SESSION_DATA_DIR:-$HOME/.claude/data/inter-session}"
msglog="$isdata/messages.log"

long=0; want_json=0
for a in "$@"; do case "$a" in
  --long|-l) long=1 ;;
  --json|-j) want_json=1 ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

# Find every team session on this socket (orch-*). tmux is team-env's wrapper: -L "$TEAM_TMUX".
mapfile -t sessions < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^orch-' || true)
if [ "${#sessions[@]}" -eq 0 ]; then
  echo "no live orchestrator sessions on socket '$TEAM_TMUX'."
  echo "(check 'tmux -L $TEAM_TMUX ls' or 'bin/team-status.sh')"
  exit 0
fi

# For each session, try to recover its TEAM_RUN_ID, state dir and bus port by scanning the
# clone's .team-*/ dirs and matching session names. team-env's hash is deterministic, so we
# can reverse the lookup by trial; the bus port comes from the same hash (team-env.sh).
declare -A rid_of=() port_of=()
for d in "$repo"/.team-* "$repo"/.team; do
  [ -d "$d" ] || continue
  # "${d##*/.team-}" leaves "$repo/.team" whole, so the legacy dir is matched by name.
  case "$d" in */.team) rid="(legacy)" ;; *) rid="${d##*/.team-}" ;; esac
  # Re-derive the session name with this rid to confirm.
  if [ "$rid" != "(legacy)" ]; then
    h="$(printf '%s\0%s' "$TEAM_REPO" "$rid" | cksum | cut -d' ' -f1)"
    sess="orch-${h: -5}"
  else
    h="$(printf '%s' "$TEAM_REPO" | cksum | cut -d' ' -f1)"
    sess="orch-${h: -5}"
  fi
  rid_of["$sess"]="$rid"
  port_of["$sess"]=$((9500 + h % 400))
done

# The last /is message from each run's orchestrator, read in ONE pass over the bus log (up to
# 50 MB). The log is shared by every bus on this machine and records no port, so a message
# belongs to a run when its sender or recipient session id is a listener on that run's port
# (the clients' state files record session_id and port). Prints "<port><TAB><snippet>".
declare -A last_msg=()
load_last_orchestrator_msgs() {
  local ports=() s p line
  for s in "${sessions[@]}"; do [ -n "${port_of[$s]:-}" ] && ports+=("${port_of[$s]}"); done
  [ "${#ports[@]}" -gt 0 ] && [ -f "$msglog" ] || return 0
  while IFS=$'\t' read -r p line; do last_msg["$p"]="$line"; done < <(python3 - "$msglog" "$isdata/clients" "${ports[@]}" <<'PY' 2>/dev/null
import sys, json, datetime, time, os, glob
logf, clients = sys.argv[1], sys.argv[2]
ports = {int(p) for p in sys.argv[3:]}
port_of_sid = {}
for f in glob.glob(os.path.join(clients, "*.session")):
    try:
        with open(f, encoding="utf-8") as fh:
            st = json.load(fh)
    except Exception:
        continue
    if isinstance(st, dict) and st.get("port") in ports and st.get("session_id"):
        port_of_sid[st["session_id"]] = st["port"]
last = {}
if port_of_sid:
    for line in open(logf, encoding="utf-8", errors="replace"):
        if '"orchestrator"' not in line:
            continue
        try: d = json.loads(line)
        except Exception: continue
        if d.get("from_name") != "orchestrator":
            continue
        p = port_of_sid.get(d.get("from")) or port_of_sid.get(d.get("to_session_id"))
        if p:
            last[p] = d
for p, d in last.items():
    text = " ".join((d.get("text") or "").split())[:60]
    age = ""
    try:
        t = datetime.datetime.fromisoformat(d["ts"])
        s = int(time.time() - t.timestamp())
        age = f" ({s}s)" if s < 60 else f" ({s//60}m)" if s < 3600 else f" ({s//3600}h)"
    except Exception: pass
    print(f"{p}\t{text}{age}")
PY
)
}
load_last_orchestrator_msgs
last_orchestrator_msg() { local p="${port_of[$1]:-}"; [ -n "$p" ] && printf '%s\n' "${last_msg[$p]:--}" || echo "-"; }

if [ "$want_json" = 1 ]; then
  echo -n '['; first=1
  for s in "${sessions[@]}"; do
    rid="${rid_of[$s]:-?}"
    age="$(tmux display-message -p -t "$s" '#{session_created}' 2>/dev/null)"
    msg="$(last_orchestrator_msg "$s" | tr -d '"')"
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
  created="$(tmux display-message -p -t "$s" '#{session_created}' 2>/dev/null)"
  if [ -n "$created" ]; then
    d=$((now - created))
    if [ "$d" -lt 60 ]; then age="${d}s"
    elif [ "$d" -lt 3600 ]; then age="$((d/60))m"
    else age="$((d/3600))h"; fi
  else age="-"; fi
  msg="$(last_orchestrator_msg "$s")"
  printf '%-13s %-22s %-7s %s\n' "$s" "${rid:0:22}" "$age" "${msg:0:50}"
  ad="$repo/.team-$rid"; [ "$rid" = "(legacy)" ] && ad="$repo/.team"
  if [ "$long" = 1 ] && [ -f "$ad/active" ]; then
    awk -F'\t' 'BEGIN {printf "                roles: "} { printf "%s ", $3 } END { print "" }' "$ad/active"
  fi
done

echo
echo "to enter a run:    TEAM_RUN_ID=<run-id> $repo/bin/attach.sh"
echo "to approve a run:  TEAM_RUN_ID=<run-id> $repo/bin/approve.sh    # sends 'go'"
echo "to inject text:    TEAM_RUN_ID=<run-id> $repo/bin/approve.sh '<text>'"

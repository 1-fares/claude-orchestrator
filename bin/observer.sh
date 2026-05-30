#!/usr/bin/env bash
# observer.sh: a periodic AI advisor on team right-sizing and host load.
#
# Unlike the api-watchdog and tmux-watchdog (mechanical: they recover stalls and
# crashes), the observer REASONS about efficiency. On a slow cadence it gathers
# host load, per-role idle/health, the unit pipeline, and bus throughput, asks a
# model for a grow/shrink/server recommendation, writes it where the dashboard
# and orchestrator can read it, and nudges the orchestrator when the advice
# changes. It RECOMMENDS, never acts: scaling stays the orchestrator's call.
#
# Env:
#   OBSERVER_DISABLED=1     do not run
#   OBSERVER_INTERVAL=900   seconds between observations (default 15 min)
#   OBSERVER_MODEL=sonnet   model for the recommendation (sonnet|haiku|opus|id)
#   OBSERVER_IDLE_SEC=1800  a role idle longer than this is shrink-eligible
#   OBSERVER_CALL_TIMEOUT=120  max seconds for one model call
#
# Started once per run by bin/lib/team-spawn.sh (idempotent via a pidfile),
# same shape as the watchdogs.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"

interval="${OBSERVER_INTERVAL:-900}"
model="${OBSERVER_MODEL:-sonnet}"
idle_sec="${OBSERVER_IDLE_SEC:-1800}"
call_timeout="${OBSERVER_CALL_TIMEOUT:-120}"
obs_dir="$TEAM_DIR/observer"
mkdir -p "$obs_dir"
last_headline=""

iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Convert team-status IDLE tokens (3s, 12m, 1h, 2d) to seconds.
idle_to_sec() {
  case "$1" in
    *s) echo "${1%s}" ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *d) echo $(( ${1%d} * 86400 )) ;;
    *) echo 0 ;;
  esac
}

# Best-effort bus nudge to the orchestrator (the poller posts the same way).
post_orch() {
  local text="$1" send
  send="$HOME/.claude/skills/is/bin/send.py"
  [ -f "$send" ] || return 0
  python3 "$send" --from observer --to orchestrator --text "$text" >/dev/null 2>&1 || true
}

gather_metrics() {
  # Host
  read -r l1 l5 l15 _ < /proc/loadavg
  local ncpu mem claude_n claude_rss
  ncpu="$(nproc)"
  mem="$(free -m | awk '/^Mem:/{printf "%d/%d MiB (%d%%)", $3, $2, ($3/$2)*100}')"
  claude_n="$(pgrep -xc claude 2>/dev/null || echo 0)"
  claude_rss="$(ps -eo rss,comm 2>/dev/null | awk '$2=="claude"{s+=$1} END{printf "%.1f", s/1024/1024}')"

  # Roster (role, idle, health) via team-status
  local status roster idle_roles=0
  status="$(TEAM_RUN_ID="${TEAM_RUN_ID:-}" "$repo/bin/team-status.sh" 2>/dev/null)"
  roster="$(printf '%s\n' "$status" | awk '$3=="yes"||$3=="no"{print $1"\t"$5"\t"$6}')"
  while IFS=$'\t' read -r role idle health; do
    [ -z "$role" ] && continue
    [ "$(idle_to_sec "$idle")" -ge "$idle_sec" ] && idle_roles=$((idle_roles+1))
  done <<< "$roster"

  # Pipeline from the unit ledger
  local pipe goal
  if [ -f "$TEAM_DIR/state.md" ]; then
    pipe="$(grep -E '^status:' "$TEAM_DIR/state.md" 2>/dev/null | sed 's/^status:[[:space:]]*//' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')"
    goal="$(grep -A3 -iE '^#* *goal' "$TEAM_DIR/state.md" 2>/dev/null | tail -n +2 | grep -m1 -vE '^[[:space:]]*$' | sed 's/^[[:space:]]*//' | head -c 200)"
  fi

  # Bus throughput over the last interval (rough liveness)
  local buslog msgs="?"
  buslog="$HOME/.claude/data/inter-session/messages.log"
  [ -f "$buslog" ] && msgs="$(tail -n 400 "$buslog" 2>/dev/null | wc -l)"

  cat <<EOF
HOST: load ${l1}/${l5}/${l15} on ${ncpu} vCPU; mem ${mem}; claude procs ${claude_n} (~${claude_rss} GiB RSS)
ROSTER (role, idle, health):
$(printf '%s\n' "$roster" | sed 's/^/  /')
SHRINK-ELIGIBLE (idle >= ${idle_sec}s): ${idle_roles}
PIPELINE (unit status counts): ${pipe:-none}
GOAL: ${goal:-unknown}
BUS: ~${msgs} recent messages logged
EOF
}

build_prompt() {
  local metrics="$1"
  cat <<EOF
You are the read-only efficiency observer for a long-running team of Claude Code
agents (an orchestrator plus worker roles, each a separate process ~300-500 MiB).
The work is API-bound: CPU is usually near-idle; the real costs are RAM per live
role and the agents' API usage. You RECOMMEND only; you never act.

Current observation:
${metrics}

In <= 12 lines, give a concrete recommendation:
1) First line EXACTLY: "HEADLINE: <one terse sentence: grow/shrink/hold + host sizing>"
2) TEAM: which roles (if any) to retire now (idle and no in-flight unit) and why;
   whether to add a role (a backlog with no owner). If none, say "hold".
3) HOST: is the instance over/under-sized for this load? (Consider: API-bound, so
   idle CPU is expected; judge on RAM headroom and peak role count, not CPU.)
4) FLAGS: anything off (a role wedged, pipeline stalled, runaway memory). Else none.
Be specific and brief. Do not suggest acting yourself; the orchestrator decides.
EOF
}

observe_once() {
  local metrics prompt out headline
  metrics="$(gather_metrics)"
  prompt="$(build_prompt "$metrics")"
  out="$(timeout "$call_timeout" claude -p "$prompt" --model "$model" 2>/dev/null)"
  [ -z "$out" ] && out="(model call failed or timed out; metrics only)"
  headline="$(printf '%s\n' "$out" | grep -m1 -E '^HEADLINE:' | sed 's/^HEADLINE:[[:space:]]*//')"

  {
    echo "# Observer recommendation"
    echo "_$(iso) - model ${model}, every ${interval}s_"
    echo
    echo '## Metrics'
    echo '```'
    printf '%s\n' "$metrics"
    echo '```'
    echo
    echo '## Recommendation'
    printf '%s\n' "$out"
  } > "$obs_dir/latest.md"
  { echo "=== $(iso) ==="; printf '%s\n' "$out"; echo; } >> "$obs_dir/history.md"

  # Nudge the orchestrator only when the headline changes (avoid nagging).
  if [ -n "$headline" ] && [ "$headline" != "$last_headline" ]; then
    post_orch "observer: ${headline} (full advice: ${obs_dir}/latest.md)"
    last_headline="$headline"
  fi
  echo "$(iso) observer: ${headline:-no headline}"
}

# --once: run a single observation and exit (testing / external schedulers).
if [ "${1:-}" = "--once" ]; then
  observe_once
  exit 0
fi

echo "observer: starting team=${TEAM_SESSION:-?} run=${TEAM_RUN_ID:-legacy} interval=${interval}s model=${model} idle>=${idle_sec}s"
while :; do
  observe_once || echo "$(iso) observer: tick error (continuing)"
  sleep "$interval"
done

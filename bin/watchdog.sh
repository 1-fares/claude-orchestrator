#!/usr/bin/env bash
# watchdog.sh: enforce a ceiling on an autonomous run. Polls wall-clock time and
# bus message volume; when either ceiling is hit, runs stop-team.sh and exits.
# Start it in the background when you set the orchestrator to autonomous mode and
# walk away. It is a safety net against runaway /goal loops and ping-pong, not a
# normal part of an attended run.
#
# Usage: bin/watchdog.sh [--max-minutes N] [--max-messages M] [--interval S]
#   defaults: 120 minutes, 2000 messages, 30s poll. Run backgrounded, e.g.:
#   nohup bin/watchdog.sh --max-minutes 90 >/tmp/team-watchdog.log 2>&1 &

set -uo pipefail
# Original invocation args, captured before any parsing, so self-reload can re-exec
# this daemon with the same flags (bin/lib/self-reload.sh).
_SR_ORIG_ARGS=("$@")

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"
# Self-reload: re-exec when this file or a lib it sources changes on disk, so a synced
# fix takes effect without a restart. 2026-09-02: this daemon kept running 24 August
# code for nine hours after the fix landed, because only api-watchdog reloaded itself.
# shellcheck source=bin/lib/self-reload.sh
. "$repo/bin/lib/self-reload.sh"
self_reload_init "$0" "$repo/bin/team-env.sh" "$repo/bin/lib/self-reload.sh"
max_min=120 max_msg=2000 interval=30
while [ $# -gt 0 ]; do
  case "$1" in
    --max-minutes)  max_min="$2"; shift 2;;
    --max-messages) max_msg="$2"; shift 2;;
    --interval)     interval="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

msglog="$HOME/.claude/data/inter-session/messages.log"
start="$(date +%s)"
base="$(wc -l < "$msglog" 2>/dev/null || echo 0)"
echo "watchdog: ceiling ${max_min}min / ${max_msg}msgs, polling every ${interval}s"

while true; do
  self_reload_check "$0" ${_SR_ORIG_ARGS[@]+"${_SR_ORIG_ARGS[@]}"}
  sleep "$interval"
  now="$(date +%s)"; el=$(( (now - start) / 60 ))
  cur="$(wc -l < "$msglog" 2>/dev/null || echo 0)"; dmsg=$(( cur - base ))
  if [ "$el" -ge "$max_min" ] || [ "$dmsg" -ge "$max_msg" ]; then
    echo "watchdog: ceiling hit (elapsed ${el}min, messages ${dmsg}); stopping team"
    "$repo/bin/stop-team.sh"
    exit 0
  fi
done

#!/usr/bin/env bash
# api-watchdog.sh: detect and auto-recover role sessions stalled by transient
# Anthropic API rate-limit / connection errors. Runs as a long-lived daemon per
# team. Three tiers in one process:
#   - Tier 1: detect + record per-role health under $TEAM_DIR/health/
#   - Tier 2: auto-send `try again` to stalled panes with exponential backoff
#   - Tier 3: orchestrator-aware (pull, not push: the orchestrator reads the
#             health files; the watchdog never pings it over /is or send-keys,
#             which avoids the feedback loop when the orchestrator itself is
#             throttled)
#
# Pure shell + curl. Never makes a Claude API call, so cannot itself be
# rate-limited.
#
# Usage:
#   bin/api-watchdog.sh                       # blocking loop (launch-team starts it)
#   bin/api-watchdog.sh --interval 30         # seconds between scans
#   bin/api-watchdog.sh --max-retries 5
#   bin/api-watchdog.sh --once                # one scan, then exit (for testing)
#
# Env:
#   API_WATCHDOG_DISABLED=1   skip auto-start entirely (in launch-team)
#   NTFY_URL=<url>            push notifications target (e.g. https://ntfy.sh/orch-example)
#   API_WATCHDOG_PATTERNS     path to a patterns file (default bin/api-watchdog.patterns)

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

interval=30
max_retries=5
backoff=(30 60 120 300 600)
once=0
patterns_file="${API_WATCHDOG_PATTERNS:-$repo/bin/api-watchdog.patterns}"

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="$2"; shift 2 ;;
    --max-retries) max_retries="$2"; shift 2 ;;
    --once) once=1; shift ;;
    --patterns) patterns_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -r "$patterns_file" ] || { echo "patterns file unreadable: $patterns_file" >&2; exit 2; }

health_dir="$TEAM_DIR/health"
audit_dir="$TEAM_DIR/audit/api-watchdog"
mkdir -p "$health_dir" "$audit_dir"

# Build a single extended-regex from the patterns file (comments + blank ignored).
pattern_regex="$(grep -vE '^[[:space:]]*(#|$)' "$patterns_file" | paste -sd'|' -)"
[ -n "$pattern_regex" ] || { echo "no patterns loaded from $patterns_file" >&2; exit 2; }

notify() {
  [ -z "${NTFY_URL:-}" ] && return 0
  curl -sS -m 5 -X POST -d "$1" "$NTFY_URL" -o /dev/null 2>/dev/null || true
}

now() { date +%s; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# classify <pane-id> -> echoes one of: active | stalled-api
# "stalled-api" requires THREE conditions on the visible bottom of the pane:
#   1. no active spinner (claude is not currently working)
#   2. the Claude-TUI input prompt marker '❯' is visible in the bottom few
#      lines, i.e. the input box is rendered (whether the line shows
#      placeholder text like '❯ Try "..."', queued user text like '❯ try again',
#      or just '❯ '). PRESENCE of '❯' is the idle marker; we cannot require an
#      empty prompt because the TUI always shows placeholder text when empty
#   3. one of the configured error patterns is visible in the recent output
#      (bottom 15 lines), not just deep scrollback
classify() {
  local visible busy idle hit
  visible="$(tmux capture-pane -t "$1" -p 2>/dev/null)"
  busy="$(printf '%s' "$visible" | tail -25 | grep -ciE 'esc to interrupt|Working…|Thinking|· ↓|tokens ·')"
  if [ "$busy" -gt 0 ]; then echo "active"; return; fi
  # Claude-TUI input box rendered => idle, waiting for input.
  idle="$(printf '%s' "$visible" | tail -8 | grep -c '❯' || true)"
  if [ "$idle" -eq 0 ]; then echo "active"; return; fi
  hit="$(printf '%s' "$visible" | tail -15 | grep -iE "$pattern_regex" | head -1 || true)"
  if [ -n "$hit" ]; then echo "stalled-api"; return; fi
  echo "active"
}

# read_field <file> <field> <default>
read_field() { jq -r --arg d "$3" --arg k "$2" '.[$k] // $d' "$1" 2>/dev/null || echo "$3"; }

write_state() {
  local f="$1" state="$2" retries="$3" last_retry="$4" since="$5"
  jq -nc --arg state "$state" \
         --argjson retries "$retries" \
         --argjson last_retry "$last_retry" \
         --argjson since "$since" \
         --argjson last_seen "$(now)" \
         '{state:$state, retries:$retries, last_retry_at:$last_retry, since:$since, last_seen:$last_seen}' \
    > "$f"
}

scan_once() {
  if ! tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then return 0; fi
  tmux list-windows -t "$TEAM_SESSION" -F '#{window_id}'$'\t''#{window_name}' 2>/dev/null \
  | while IFS=$'\t' read -r wid name; do
      [ -n "$name" ] || continue
      state="$(classify "$wid")"
      hf="$health_dir/$name.json"
      af="$audit_dir/$name.log"
      [ -f "$hf" ] || echo '{}' > "$hf"
      prev="$(jq -r '.state // "unknown"' "$hf" 2>/dev/null)"
      retries=$(read_field "$hf" retries 0)
      last_retry=$(read_field "$hf" last_retry_at 0)
      since=$(read_field "$hf" since 0)
      nowts=$(now)

      case "$state" in
        stalled-api)
          if [ "$prev" != "stalled-api" ] && [ "$prev" != "give-up" ]; then
            since=$nowts; retries=0; last_retry=0
            echo "$(iso "$nowts") [$name] STALLED (api/network error)" >> "$af"
            notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' stalled (API/network); watchdog retrying"
          fi
          if [ "$prev" = "give-up" ]; then
            # already given up; only write state, do not retry or notify again
            write_state "$hf" "give-up" "$retries" "$last_retry" "$since"
            continue
          fi
          # Retry decision
          if [ "$retries" -ge "$max_retries" ]; then
            echo "$(iso "$nowts") [$name] GIVE-UP after $retries retries" >> "$af"
            notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' stuck after $retries retries; manual intervention needed"
            write_state "$hf" "give-up" "$retries" "$last_retry" "$since"
            continue
          fi
          idx="$retries"; [ "$idx" -ge "${#backoff[@]}" ] && idx=$((${#backoff[@]} - 1))
          required=${backoff[$idx]}
          elapsed=$((nowts - last_retry))
          if [ "$last_retry" -eq 0 ] || [ "$elapsed" -ge "$required" ]; then
            # Send "try again" + Enter
            tmux send-keys -t "$wid" -l 'try again' 2>/dev/null && \
              tmux send-keys -t "$wid" Enter 2>/dev/null || true
            retries=$((retries + 1)); last_retry=$nowts
            echo "$(iso "$nowts") [$name] retry $retries/$max_retries (waited ${required}s)" >> "$af"
          fi
          write_state "$hf" "stalled-api" "$retries" "$last_retry" "$since"
          ;;
        active)
          if [ "$prev" = "stalled-api" ] || [ "$prev" = "give-up" ]; then
            echo "$(iso "$nowts") [$name] RECOVERED after $retries retries" >> "$af"
            notify "🟢 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' recovered"
          fi
          write_state "$hf" "active" 0 0 "$nowts"
          ;;
      esac
    done
}

echo "api-watchdog: starting team=$TEAM_SESSION run=${TEAM_RUN_ID:-legacy} interval=${interval}s max-retries=$max_retries ntfy=${NTFY_URL:-<unset>}"
if [ "$once" = 1 ]; then
  scan_once; exit 0
fi
trap 'echo "api-watchdog: stopping"; exit 0' TERM INT
while true; do
  scan_once
  sleep "$interval"
done

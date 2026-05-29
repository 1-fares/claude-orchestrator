#!/usr/bin/env bash
# api-watchdog.sh: detect and auto-recover unhealthy role sessions. Long-lived
# daemon, one per team. Covers two distinct failure modes in one scan loop:
#
#   A. API-STALL  — a role idled at the input prompt because a transient
#      Anthropic API rate-limit / connection error aborted its turn. Recovery:
#      auto-send `try again` with exponential backoff (Tier 2), give up after
#      max-retries.
#
#   B. STUCK      — a role is "busy" (a spinner is on screen) but its pane
#      content has not changed for a long time: it is wedged on a hung tool
#      call (the classic case is a chrome-devtools MCP call that never returns
#      after the debug Chrome dies). The api-stall detector CANNOT see this —
#      a spinner reads as "active" — so a wedged role silently stalls the whole
#      run while reporting healthy. Recovery ladder:
#        Tier 1 (gentle, autonomous): send Escape to interrupt the hung call,
#                then a one-line nudge to the role's OWN pane. Preserves the
#                role's context; recovers most wedges with nobody watching.
#        Tier 2 (escalation): after STUCK_MAX_NUDGES failed nudges, mark health
#                state "stuck-giveup", ntfy, and message the orchestrator to
#                retire+respawn the role (it holds the goal/context to re-brief).
#                If the STUCK role IS the orchestrator, ntfy + write PENDING.md
#                for the operator instead of pinging itself.
#
# Health per role is recorded under $TEAM_DIR/health/<role>.json with a single
# `state` field: active | stalled-api | stuck | stuck-giveup | give-up. The
# orchestrator reads these (pull-based, Tier-3 awareness).
#
# Pure shell + curl + jq + tmux. Never makes a Claude API call, so cannot
# itself be rate-limited.
#
# Usage:
#   bin/api-watchdog.sh                       # blocking loop (launch-team starts it)
#   bin/api-watchdog.sh --interval 30         # seconds between scans
#   bin/api-watchdog.sh --max-retries 5
#   bin/api-watchdog.sh --once                # one scan, then exit (for testing)
#
# Env:
#   API_WATCHDOG_DISABLED=1   skip auto-start entirely (in launch-team)
#   STUCK_WATCHDOG_DISABLED=1 keep api-stall recovery, disable stuck detection
#   STUCK_THRESHOLD_SEC=480   pane unchanged while busy this long => stuck (8 min)
#   STUCK_MAX_NUDGES=2        gentle interrupt+nudge attempts before escalation
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
stuck_disabled="${STUCK_WATCHDOG_DISABLED:-0}"
stuck_threshold="${STUCK_THRESHOLD_SEC:-480}"
stuck_max_nudges="${STUCK_MAX_NUDGES:-2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="$2"; shift 2 ;;
    --max-retries) max_retries="$2"; shift 2 ;;
    --once) once=1; shift ;;
    --patterns) patterns_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
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

# Pure stdin-based pane detectors (BUSY_RE, VOLATILE_RE, _classify_text,
# _is_busy_text, _fingerprint_text). Factored to bin/lib/ so they unit-test
# without a live tmux / the daemon loop.
. "$repo/bin/lib/watchdog-detect.sh"

notify() {
  [ -z "${NTFY_URL:-}" ] && return 0
  curl -sS -m 5 -X POST -d "$1" "$NTFY_URL" -o /dev/null 2>/dev/null || true
}

now() { date +%s; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# ---- tmux-bound wrappers ----------------------------------------------------

classify()        { tmux capture-pane -t "$1" -p 2>/dev/null | _classify_text; }
pane_is_busy()    { tmux capture-pane -t "$1" -p 2>/dev/null | _is_busy_text; }
pane_fingerprint(){ tmux capture-pane -t "$1" -p 2>/dev/null | _fingerprint_text; }

# read_field <file> <field> <default>
read_field() { jq -r --arg d "$3" --arg k "$2" '.[$k] // $d' "$1" 2>/dev/null || echo "$3"; }

# persist <file> + all fields. One writer for both failure modes so neither
# clobbers the other's bookkeeping.
persist() {
  local f="$1" state="$2" retries="$3" last_retry="$4" since="$5" \
        fp="$6" fp_since="$7" nudge_fp="$8" nudge_count="$9" last_nudge="${10}"
  jq -nc --arg state "$state" \
         --argjson retries "$retries" \
         --argjson last_retry "$last_retry" \
         --argjson since "$since" \
         --argjson last_seen "$(now)" \
         --arg fp "$fp" \
         --argjson fp_since "$fp_since" \
         --arg nudge_fp "$nudge_fp" \
         --argjson nudge_count "$nudge_count" \
         --argjson last_nudge "$last_nudge" \
         '{state:$state, retries:$retries, last_retry_at:$last_retry, since:$since,
           last_seen:$last_seen, fp:$fp, fp_since:$fp_since, nudge_fp:$nudge_fp,
           nudge_count:$nudge_count, last_nudge_at:$last_nudge}' \
    > "$f"
}

# send a gentle interrupt + nudge to a wedged role's OWN pane.
nudge_pane() {
  local wid="$1" mins="$2"
  tmux send-keys -t "$wid" Escape 2>/dev/null || true
  sleep 0.4
  tmux send-keys -t "$wid" -l "[watchdog] your last action produced no output for ~${mins}m and looks hung; an Escape was just sent to interrupt it. Abandon that tool call, try a different approach, or report the blocker on the bus (do not silently retry the same call)." 2>/dev/null || true
  tmux send-keys -t "$wid" Enter 2>/dev/null || true
}

# escalate a wedged role to the orchestrator (it holds the goal/context to
# retire+respawn). Pull-safe: a STUCK role is rarely correlated with the
# orchestrator's own health (unlike an API stall), so a one-shot push is fine.
# Never ping the orchestrator about itself.
escalate_stuck() {
  local name="$1" mins="$2"
  if [ "$name" = "orchestrator" ]; then
    {
      echo "# Orchestrator wedged"
      echo
      echo "The orchestrator pane has shown no progress for ~${mins}m while busy"
      echo "(stuck on a hung tool call). The watchdog cannot recover it on its own."
      echo "Recovery: attach (TEAM_RUN_ID=$TEAM_RUN_ID bin/attach.sh), send Escape,"
      echo "and re-prompt; if unrecoverable, reset and relaunch from state.md."
    } > "$TEAM_DIR/PENDING.md" 2>/dev/null || true
    notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] ORCHESTRATOR wedged ~${mins}m; operator intervention needed (see PENDING.md)"
    return
  fi
  local msg="[watchdog] role '$name' is wedged: ~${mins}m with no pane progress while busy, and ${stuck_max_nudges} interrupt+nudge attempts did not clear it (likely a hung tool call, e.g. the chrome-devtools MCP). Recommend retire+respawn: bin/retire-role.sh $name --force --reason 'stuck/hung tool call' then bin/add-role.sh <goal> $name, then re-brief it on its in-flight unit."
  tmux send-keys -t "$TEAM_SESSION:orchestrator" -l "$msg" 2>/dev/null && \
    tmux send-keys -t "$TEAM_SESSION:orchestrator" Enter 2>/dev/null || true
  notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' wedged ~${mins}m, ${stuck_max_nudges} nudges failed; asked orchestrator to retire+respawn"
}

scan_once() {
  if ! tmux has-session -t "$TEAM_SESSION" 2>/dev/null; then return 0; fi
  tmux list-windows -t "$TEAM_SESSION" -F '#{window_id}'$'\t''#{window_name}' 2>/dev/null \
  | while IFS=$'\t' read -r wid name; do
      [ -n "$name" ] || continue
      visible="$(tmux capture-pane -t "$wid" -p 2>/dev/null)"
      state="$(printf '%s' "$visible" | _classify_text)"
      busy=0; printf '%s' "$visible" | _is_busy_text && busy=1
      fp="$(printf '%s' "$visible" | _fingerprint_text)"

      hf="$health_dir/$name.json"
      af="$audit_dir/$name.log"
      [ -f "$hf" ] || echo '{}' > "$hf"
      prev="$(jq -r '.state // "unknown"' "$hf" 2>/dev/null)"
      retries=$(read_field "$hf" retries 0)
      last_retry=$(read_field "$hf" last_retry_at 0)
      since=$(read_field "$hf" since 0)
      prev_fp=$(read_field "$hf" fp "")
      fp_since=$(read_field "$hf" fp_since 0)
      nudge_fp=$(read_field "$hf" nudge_fp "")
      nudge_count=$(read_field "$hf" nudge_count 0)
      last_nudge=$(read_field "$hf" last_nudge_at 0)
      nowts=$(now)

      # --- A. API-STALL path (idle at prompt with an error pattern) ----------
      if [ "$state" = "stalled-api" ]; then
        if [ "$prev" != "stalled-api" ] && [ "$prev" != "give-up" ]; then
          since=$nowts; retries=0; last_retry=0
          echo "$(iso "$nowts") [$name] STALLED (api/network error)" >> "$af"
          notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' stalled (API/network); watchdog retrying"
        fi
        if [ "$prev" = "give-up" ]; then
          persist "$hf" "give-up" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
          continue
        fi
        if [ "$retries" -ge "$max_retries" ]; then
          echo "$(iso "$nowts") [$name] GIVE-UP after $retries retries" >> "$af"
          notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' stuck after $retries retries; manual intervention needed"
          persist "$hf" "give-up" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
          continue
        fi
        idx="$retries"; [ "$idx" -ge "${#backoff[@]}" ] && idx=$((${#backoff[@]} - 1))
        required=${backoff[$idx]}
        elapsed=$((nowts - last_retry))
        if [ "$last_retry" -eq 0 ] || [ "$elapsed" -ge "$required" ]; then
          tmux send-keys -t "$wid" -l 'try again' 2>/dev/null && \
            tmux send-keys -t "$wid" Enter 2>/dev/null || true
          retries=$((retries + 1)); last_retry=$nowts
          echo "$(iso "$nowts") [$name] retry $retries/$max_retries (waited ${required}s)" >> "$af"
        fi
        persist "$hf" "stalled-api" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
        continue
      fi

      # --- B. STUCK path (busy spinner, but pane content frozen) -------------
      if [ "$busy" = 1 ] && [ "$stuck_disabled" != 1 ]; then
        if [ "$fp" != "$prev_fp" ]; then
          # Real progress (or the model responding to our nudge): reset tracking.
          if [ "$prev" = "stuck" ] || [ "$prev" = "stuck-giveup" ]; then
            echo "$(iso "$nowts") [$name] RECOVERED-STUCK (pane progressing again)" >> "$af"
            notify "🟢 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' un-wedged"
          fi
          persist "$hf" "active" 0 0 "$nowts" "$fp" "$nowts" "$nudge_fp" "$nudge_count" "$last_nudge"
          continue
        fi
        # Content unchanged since fp_since.
        frozen=$((nowts - fp_since))
        if [ "$fp_since" -eq 0 ]; then frozen=0; fp_since=$nowts; fi
        if [ "$frozen" -lt "$stuck_threshold" ]; then
          # busy and tracking, not yet stuck
          persist "$hf" "active" 0 0 "$nowts" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
          continue
        fi
        mins=$((frozen / 60))
        if [ "$nudge_fp" = "$fp" ]; then
          # We already nudged for THIS exact frozen content and it is STILL
          # frozen: the gentle interrupt did not take. Escalate.
          if [ "$prev" != "stuck-giveup" ]; then
            echo "$(iso "$nowts") [$name] STUCK-GIVEUP (nudge ineffective, frozen ${mins}m)" >> "$af"
            escalate_stuck "$name" "$mins"
          fi
          persist "$hf" "stuck-giveup" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$nowts"
          continue
        fi
        nudge_count=$((nudge_count + 1))
        if [ "$nudge_count" -gt "$stuck_max_nudges" ]; then
          echo "$(iso "$nowts") [$name] STUCK-GIVEUP after $((nudge_count-1)) nudges (frozen ${mins}m)" >> "$af"
          escalate_stuck "$name" "$mins"
          persist "$hf" "stuck-giveup" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$fp" "$nudge_count" "$nowts"
          continue
        fi
        if [ "$prev" != "stuck" ]; then
          echo "$(iso "$nowts") [$name] STUCK (busy + pane frozen ${mins}m); interrupt+nudge $nudge_count/$stuck_max_nudges" >> "$af"
          notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' wedged ${mins}m (hung tool call); watchdog sending interrupt+nudge"
        else
          echo "$(iso "$nowts") [$name] STUCK still (frozen ${mins}m); interrupt+nudge $nudge_count/$stuck_max_nudges" >> "$af"
        fi
        nudge_pane "$wid" "$mins"
        # Mark the fp we nudged on; if it is STILL this fp next time => escalate.
        persist "$hf" "stuck" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$fp" "$nudge_count" "$nowts"
        continue
      fi

      # --- C. ACTIVE / IDLE (not stalled, not busy-frozen) -------------------
      if [ "$prev" = "stalled-api" ] || [ "$prev" = "give-up" ]; then
        echo "$(iso "$nowts") [$name] RECOVERED after $retries retries" >> "$af"
        notify "🟢 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' recovered"
      elif [ "$prev" = "stuck" ] || [ "$prev" = "stuck-giveup" ]; then
        echo "$(iso "$nowts") [$name] RECOVERED-STUCK (back at prompt)" >> "$af"
        notify "🟢 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' un-wedged"
      fi
      # genuinely active/idle: reset both api-stall and stuck bookkeeping.
      persist "$hf" "active" 0 0 "$nowts" "$fp" "$nowts" "" 0 0
    done
}

echo "api-watchdog: starting team=$TEAM_SESSION run=${TEAM_RUN_ID:-legacy} interval=${interval}s max-retries=$max_retries stuck=$([ "$stuck_disabled" = 1 ] && echo off || echo "${stuck_threshold}s/${stuck_max_nudges}nudges") ntfy=${NTFY_URL:-<unset>}"
if [ "$once" = 1 ]; then
  scan_once; exit 0
fi
trap 'echo "api-watchdog: stopping"; exit 0' TERM INT
while true; do
  scan_once
  sleep "$interval"
done

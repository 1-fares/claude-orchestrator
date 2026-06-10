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
#                state "stuck-giveup" and message the orchestrator to retire+
#                respawn the role (it holds the goal/context to re-brief). This is
#                automated, so it does NOT push the operator.
#        Tier 3 (operator): only when automation is exhausted and a human is the
#                only recourse does an ntfy push fire. Four cases, all of them
#                require the operator to act: the orchestrator itself is wedged
#                (PENDING.md), an API stall exhausts its retries, a worker is STILL
#                wedged past STUCK_OPERATOR_SEC after the auto retire+respawn failed
#                to clear it, or the whole tmux team crashed (tmux-watchdog).
#                Transient wedges, nudges, retries, and recoveries are LOGGED to the
#                audit trail but never pushed: the operator is paged for stuck, not
#                for self-healing.
#
# Health per role is recorded under $TEAM_DIR/health/<role>.json with a single
# `state` field: active | stalled-api | stuck | stuck-giveup | give-up |
# awaiting-input | awaiting-input-esc. The orchestrator reads these (pull-based,
# Tier-3 awareness).
#
#   C. AWAITING-INPUT — a role is blocked on an interactive prompt (a selection
#      menu / confirmation) with no spinner: it cannot proceed without a human.
#      The api-stall and stuck detectors both miss this (no error pattern, no
#      spinner), so a blocked role reads as a healthy idle one and silently
#      stalls the run. No automated recovery is possible (only a human answers),
#      so after AWAIT_OPERATOR_SEC the watchdog escalates ONCE: it writes a
#      marker $TEAM_DIR/health/awaiting-<role>.md (an external watcher can see
#      it even with NTFY unset) and pushes the operator. Cleared when the prompt
#      clears.
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
# Total frozen time past which a STILL-wedged worker means the orchestrator's
# auto retire+respawn did NOT clear it, so the operator is the only recourse and
# we push ONCE. Transient wedges that the nudge/respawn clears never reach here.
stuck_operator_sec="${STUCK_OPERATOR_SEC:-$((stuck_threshold + 600))}"
# AWAITING-INPUT: a role blocked on an interactive prompt (selection menu /
# confirmation) cannot proceed without a human. There is no automated recovery
# (only a human can answer), so after this long we escalate ONCE to the operator
# and drop a marker file an external watcher can see. Lower than the stuck path:
# a blocked prompt is dead time from the first second, not a maybe-transient wedge.
await_disabled="${AWAIT_WATCHDOG_DISABLED:-0}"
await_operator_sec="${AWAIT_OPERATOR_SEC:-300}"

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

# Singleton guard (daemon mode only). Two live api-watchdogs would double every
# push, so refuse to double-start. Verify the pidfile's pid is actually an
# api-watchdog, not just any live pid: after pid reuse a stale pidfile would
# otherwise either lock us out or be ignored. Mirrors tmux-watchdog's guard.
if [ "$once" = 0 ]; then
  watchdog_pidf="$TEAM_DIR/api-watchdog.pid"
  if [ -f "$watchdog_pidf" ]; then
    _prev=$(cat "$watchdog_pidf" 2>/dev/null || echo 0)
    if [ "$_prev" != 0 ] && kill -0 "$_prev" 2>/dev/null \
         && ps -p "$_prev" -o args= 2>/dev/null | grep -q 'api-watchdog'; then
      echo "api-watchdog already running (pid $_prev)"; exit 0
    fi
  fi
  echo $$ > "$watchdog_pidf"
  trap 'rm -f "$watchdog_pidf"' EXIT
fi

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
         --arg tok "${tok:-}" \
         '{state:$state, retries:$retries, last_retry_at:$last_retry, since:$since,
           last_seen:$last_seen, fp:$fp, fp_since:$fp_since, nudge_fp:$nudge_fp,
           nudge_count:$nudge_count, last_nudge_at:$last_nudge, tok:$tok}' \
    > "$f"
}

# send a gentle interrupt + nudge to a wedged role's OWN pane.
nudge_pane() {
  local wid="$1" mins="$2"
  tmux send-keys -t "$wid" Escape 2>/dev/null || true
  sleep 0.4
  tmux_submit "$wid" "[watchdog] your last action produced no output for ~${mins}m and looks hung; an Escape was just sent to interrupt it. Abandon that tool call, try a different approach, or report the blocker on the bus (do not silently retry the same call)."
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
    } > "$TEAM_DIR/PENDING.md.tmp.$$" 2>/dev/null \
      && mv -f "$TEAM_DIR/PENDING.md.tmp.$$" "$TEAM_DIR/PENDING.md" 2>/dev/null \
      || rm -f "$TEAM_DIR/PENDING.md.tmp.$$" 2>/dev/null || true
    notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] ORCHESTRATOR wedged ~${mins}m; operator intervention needed (see PENDING.md)"
    return
  fi
  local msg="[watchdog] role '$name' is wedged: ~${mins}m with no pane progress while busy, and ${stuck_max_nudges} interrupt+nudge attempts did not clear it (likely a hung tool call, e.g. the chrome-devtools MCP). Recommend retire+respawn: bin/retire-role.sh $name --force --reason 'stuck/hung tool call' then bin/add-role.sh <goal> $name, then re-brief it on its in-flight unit."
  tmux_submit "$TEAM_SESSION:orchestrator" "$msg"
  # NO operator push here: asking the orchestrator to retire+respawn is automated
  # recovery, not something the operator must act on. If that respawn does not
  # clear the wedge, the scan loop re-escalates to the operator (stuck_operator_sec).
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
      tok="$(printf '%s' "$visible" | _token_readout)"

      hf="$health_dir/$name.json"
      af="$audit_dir/$name.log"
      [ -f "$hf" ] || echo '{}' > "$hf"
      prev="$(jq -r '.state // "unknown"' "$hf" 2>/dev/null)"
      retries=$(read_field "$hf" retries 0)
      last_retry=$(read_field "$hf" last_retry_at 0)
      since=$(read_field "$hf" since 0)
      prev_fp=$(read_field "$hf" fp "")
      prev_tok=$(read_field "$hf" tok "")
      fp_since=$(read_field "$hf" fp_since 0)
      nudge_fp=$(read_field "$hf" nudge_fp "")
      nudge_count=$(read_field "$hf" nudge_count 0)
      last_nudge=$(read_field "$hf" last_nudge_at 0)
      nowts=$(now)

      # Recover from a prior awaiting-input the moment the prompt clears (a human
      # answered, or it moved on to work/idle), whatever state it moved to. Drop
      # the operator marker so the external watcher stops flagging it.
      if [ "$state" != "awaiting-input" ] && { [ "$prev" = "awaiting-input" ] || [ "$prev" = "awaiting-input-esc" ]; }; then
        echo "$(iso "$nowts") [$name] RECOVERED-AWAIT (interactive prompt cleared)" >> "$af"
        rm -f "$health_dir/awaiting-$name.md" 2>/dev/null || true
      fi

      # --- A. API-STALL path (idle at prompt with an error pattern) ----------
      if [ "$state" = "stalled-api" ]; then
        if [ "$prev" != "stalled-api" ] && [ "$prev" != "give-up" ]; then
          since=$nowts; retries=0; last_retry=0
          echo "$(iso "$nowts") [$name] STALLED (api/network error)" >> "$af"
          # No operator push: the watchdog auto-retries with backoff. Only the
          # terminal give-up (retries exhausted) below pushes.
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

      # --- D. AWAITING-INPUT path (blocked on an interactive operator prompt) -
      # A selection menu / confirmation is on screen: the session is blocked
      # until a human answers and nothing in the run proceeds. There is NO
      # automated recovery (only a human can answer), so once it has waited past
      # await_operator_sec we escalate ONCE: write a marker file an external
      # watcher (laptop observer, dashboard) can see, and push the operator.
      # Re-armed by the RECOVERED-AWAIT cleanup above when the prompt clears.
      if [ "$state" = "awaiting-input" ] && [ "$await_disabled" != 1 ]; then
        if [ "$prev" != "awaiting-input" ] && [ "$prev" != "awaiting-input-esc" ]; then
          since=$nowts
          echo "$(iso "$nowts") [$name] AWAITING-INPUT (blocked on interactive prompt)" >> "$af"
        fi
        [ "$since" -eq 0 ] && since=$nowts
        waited=$((nowts - since))
        if [ "$prev" != "awaiting-input-esc" ] && [ "$waited" -ge "$await_operator_sec" ]; then
          mins=$((waited / 60))
          marker="$health_dir/awaiting-$name.md"
          {
            echo "# Operator decision needed — role '$name' blocked ${mins}m"
            echo
            echo "_$(iso "$nowts")_ — '$name' is waiting on an interactive prompt"
            echo "(selection menu / confirmation). Nothing in the run proceeds"
            echo "until a human answers. Attach: TEAM_RUN_ID=${TEAM_RUN_ID:-legacy} bin/attach.sh"
            echo
            echo '```'
            printf '%s\n' "$visible" | tail -20
            echo '```'
          } > "$marker" 2>/dev/null || true
          echo "$(iso "$nowts") [$name] AWAITING-INPUT-ESCALATED (blocked ${mins}m; marker=$marker)" >> "$af"
          notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' blocked ${mins}m on an interactive prompt; operator decision needed (see $marker)"
          persist "$hf" "awaiting-input-esc" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
          continue
        fi
        # Not yet past threshold, or already escalated: hold state (do not
        # downgrade an -esc back to awaiting-input, or it would re-escalate).
        newstate="awaiting-input"; [ "$prev" = "awaiting-input-esc" ] && newstate="awaiting-input-esc"
        persist "$hf" "$newstate" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
        continue
      fi

      # --- B. STUCK path (busy spinner, but no liveness) ---------------------
      # Liveness = pane content changed OR the streaming token count advanced.
      # The token readout climbs while the model streams or THINKS but freezes
      # on a hung tool call, so a long legitimate think (static body, climbing
      # tokens) is correctly treated as alive, not wedged.
      alive=0
      [ "$fp" != "$prev_fp" ] && alive=1
      [ -n "$tok" ] && [ "$tok" != "$prev_tok" ] && alive=1
      if [ "$busy" = 1 ] && [ "$stuck_disabled" != 1 ]; then
        if [ "$alive" = 1 ]; then
          # Real progress (or the model responding to our nudge): reset tracking.
          if [ "$prev" = "stuck" ] || [ "$prev" = "stuck-giveup" ] || [ "$prev" = "stuck-giveup-esc" ]; then
            echo "$(iso "$nowts") [$name] RECOVERED-STUCK (pane progressing again)" >> "$af"
            # No push: a wedge that recovered is not actionable. Logged only.
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
          # frozen: the gentle interrupt did not take.
          if [ "$prev" != "stuck-giveup" ] && [ "$prev" != "stuck-giveup-esc" ]; then
            # First give-up: log + ask the orchestrator to retire+respawn. This is
            # AUTOMATED recovery, so NO operator push yet.
            echo "$(iso "$nowts") [$name] STUCK-GIVEUP (nudge ineffective, frozen ${mins}m); asked orchestrator to retire+respawn" >> "$af"
            escalate_stuck "$name" "$mins"
            persist "$hf" "stuck-giveup" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$nowts"
            continue
          fi
          # Already gave up and the orchestrator was asked to retire+respawn, but
          # the pane is STILL frozen on the same content (a respawn would change the
          # pane), so the automated recovery did NOT clear it. Once it has stayed
          # frozen past the operator threshold, a human is the only recourse: push
          # ONCE (mark -esc so it never repeats).
          if [ "$prev" = "stuck-giveup" ] && [ "$frozen" -ge "$stuck_operator_sec" ]; then
            echo "$(iso "$nowts") [$name] STUCK-UNRECOVERED (frozen ${mins}m; auto retire+respawn did not clear it)" >> "$af"
            notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' STILL stuck ${mins}m; auto retire+respawn did not clear it, manual intervention needed"
            persist "$hf" "stuck-giveup-esc" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$nowts"
            continue
          fi
          # Still frozen, waiting on auto-recovery (or already escalated): just persist
          # the current giveup state, no repeat push.
          persist "$hf" "$prev" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$nowts"
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
          # No operator push: the watchdog is auto-nudging. Only a wedge that the
          # nudge AND the orchestrator respawn both fail to clear escalates (above).
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
        # No push: recovery is not actionable. Logged only.
      elif [ "$prev" = "stuck" ] || [ "$prev" = "stuck-giveup" ] || [ "$prev" = "stuck-giveup-esc" ]; then
        echo "$(iso "$nowts") [$name] RECOVERED-STUCK (back at prompt)" >> "$af"
        # No push: recovery is not actionable. Logged only.
      fi
      # genuinely active/idle: reset both api-stall and stuck bookkeeping.
      persist "$hf" "active" 0 0 "$nowts" "$fp" "$nowts" "" 0 0
    done
}

echo "api-watchdog: starting team=$TEAM_SESSION run=${TEAM_RUN_ID:-legacy} interval=${interval}s max-retries=$max_retries stuck=$([ "$stuck_disabled" = 1 ] && echo off || echo "${stuck_threshold}s/${stuck_max_nudges}nudges") await=$([ "$await_disabled" = 1 ] && echo off || echo "${await_operator_sec}s") ntfy=${NTFY_URL:-<unset>}"
if [ "$once" = 1 ]; then
  scan_once; exit 0
fi
trap 'echo "api-watchdog: stopping"; exit 0' TERM INT
while true; do
  scan_once
  sleep "$interval"
done

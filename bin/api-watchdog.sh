#!/usr/bin/env bash
# api-watchdog.sh: detect and auto-recover unhealthy role sessions. Long-lived
# daemon, one per team. Covers two distinct failure modes in one scan loop:
#
#   A. API-STALL  — a role idled at the input prompt because a transient
#      Anthropic API rate-limit / connection error aborted its turn. Recovery:
#      auto-send `try again` with exponential backoff (Tier 2). The retry count
#      is EPISODE-scoped (marker file, API_EPISODE_WINDOW_SEC): each retry makes
#      the pane busy for a scan or two, and without the marker the busy path's
#      counter reset let a role loop the same error forever without escalating.
#      After max-retries in one episode: give-up = ntfy push + a message to the
#      orchestrator with the error line (it owns the recovery ladder — e.g. for
#      content-filter blocks: split, sub-agent, or respawn the owner).
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
# `state` field: active | stalled-api | stalled-usage | stuck | stuck-giveup |
# give-up | awaiting-input | awaiting-input-esc. The orchestrator reads these
# (pull-based, Tier-3 awareness).
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
#   E. USAGE-STALL — the account ran out of usage/credits and Claude Code
#      parked the session on a modal dialog ("Stop and wait for limit to
#      reset / Add funds ... / Enter to confirm"). Before this class existed
#      the dialog fell through every net (no spinner, no API-error text, no
#      'Enter to select' footer, and a '❯' on its selected option satisfied the
#      idle-prompt check), so stalled roles classified healthy-idle and a real
#      usage outage silently parked most of a team (2026-07-10). Unlike
#      AWAITING-INPUT this IS auto-recoverable: Escape dismisses the modal,
#      then a "try again" nudge resumes the turn once usage returns. If usage
#      is still exhausted the next attempt re-opens the dialog and the next
#      scan retries, so recovery is retried indefinitely on a flat
#      USAGE_RETRY_SEC cadence (default 300s) — a usage window can be gone for
#      hours and giving up would strand the team exactly when it becomes
#      recoverable. The operator is pushed ONCE on entry (usage exhaustion is
#      operator-actionable: add funds or wait) and the recovery is logged.
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
#   USAGE_RETRY_SEC=300       flat cadence for usage-limit dialog recovery retries
#   USAGE_WAKE_DEDUPE_SEC=3600  min seconds between "usage outage may be over"
#                             wake-up nudges to the orchestrator
#   API_EPISODE_WINDOW_SEC=1800  api-stalls separated by less than this are ONE
#                             episode; the retry count persists across the busy
#                             blips between retries (see the A. path below)
#   API_BACKOFF_SEC="30 60 120 300 600"  space-separated retry backoff schedule
#   NTFY_URL=<url>            push notifications target (e.g. https://ntfy.sh/orch-example)
#   API_WATCHDOG_PATTERNS     path to a patterns file (default bin/api-watchdog.patterns)

set -uo pipefail
# Capture the ORIGINAL invocation args before the arg-parse loop consumes them, so
# self-reload can re-exec this daemon with the same flags (see bin/lib/self-reload.sh).
_SR_ORIG_ARGS=("$@")
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo/bin/team-env.sh"

interval=30
max_retries=5
read -r -a backoff <<< "${API_BACKOFF_SEC:-30 60 120 300 600}"
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
# USAGE-STALL: flat retry cadence for the usage-limit dialog. No max: a retry
# is cheap and idempotent (Escape + "try again" while the dialog is up just
# re-opens it), and the outage ends on the account's schedule, not ours.
usage_retry_sec="${USAGE_RETRY_SEC:-300}"
# API-STALL episode window: a "try again" makes the pane busy for a scan or
# two, the busy path resets the health-file counters, and without a memory the
# retry count restarted at 0 on every re-entry — a role stalling on the SAME
# error (classically a content-filter block) retried forever and never reached
# give-up (observed: 7h at "retry 1/5" on one blocked document, 2026-07-11).
# Stalls separated by less than this window are ONE episode; the count and
# backoff pacing persist across the blips via a marker file (the same
# treatment the usage path got for its push/nudge pacing).
episode_window="${API_EPISODE_WINDOW_SEC:-1800}"

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
  # Hard singleton: an exclusive flock on a dedicated fd. Unlike the pidfile
  # check below, the kernel releases it automatically when this process dies (so
  # it never goes stale) AND it blocks a hand-rolled `nohup api-watchdog.sh &`
  # start that bypassed the pidfile guard -- the duplicate case where a manual
  # restart ran two watchdogs and doubled every nudge. fd 200, NOT fd 9: fd 9 is
  # the roster lock the daemon deliberately drops (9>&-). The pidfile stays below
  # for tmux-watchdog's ensure probe and for pid bookkeeping.
  _lockf="${API_WATCHDOG_LOCK:-$TEAM_DIR/api-watchdog.lock}"
  if command -v flock >/dev/null 2>&1 && exec 200>"$_lockf"; then
    if ! flock -n 200; then
      echo "api-watchdog already running (lock $_lockf held); exiting"; exit 0
    fi
  fi
  watchdog_pidf="$TEAM_DIR/api-watchdog.pid"
  if [ -f "$watchdog_pidf" ]; then
    _prev=$(cat "$watchdog_pidf" 2>/dev/null || echo 0)
    # $_prev == $$ means the launcher (team-spawn start guard) already recorded
    # THIS process in the pidfile before our guard ran; treating it as a live
    # peer makes every launcher-started daemon exit at birth.
    if [ "$_prev" != 0 ] && [ "$_prev" != "$$" ] && kill -0 "$_prev" 2>/dev/null \
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
# Self-reload: re-exec this daemon when its own source or a sourced lib changes on disk,
# so a committed fix takes effect without a manual restart. Track $0 + every lib sourced
# above. Checked once per loop below.
. "$repo/bin/lib/self-reload.sh"
self_reload_init "$0" \
  "$repo/bin/team-env.sh" \
  "$repo/bin/lib/tmux-submit.sh" \
  "$repo/bin/lib/watchdog-detect.sh" \
  "$repo/bin/lib/self-reload.sh"

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
  # Numeric fields feed `jq --argjson`, which throws "invalid JSON text" on an empty
  # string (the paneless/retired-role path can leave one or more unset). A missing
  # counter/timestamp means "none yet" -> 0; default before the jq call so persist()
  # never aborts (an unguarded empty here spammed the watchdog log with jq errors).
  retries="${retries:-0}"; last_retry="${last_retry:-0}"; since="${since:-0}"
  fp_since="${fp_since:-0}"; nudge_count="${nudge_count:-0}"; last_nudge="${last_nudge:-0}"
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

# escalate an api-stall whose episode exhausted its retries to the orchestrator.
# A plain retry that failed max_retries times in one episode will not clear on
# its own; the orchestrator owns the recovery ladder. The classic case is a
# content-filter block, where the ladder is: split the unit into smaller
# chunks, delegate the blocked passage to a sub-agent writing straight to the
# file, or retire+respawn the owner if its session context is filter-poisoned.
# Never ping the orchestrator about itself (the give-up ntfy push covers that).
# The raw error line is deliberately NOT quoted into the pane: injected verbatim
# it would itself match the stall patterns on the orchestrator's pane and make
# the next scan classify the ORCHESTRATOR stalled-api. It lives in the audit
# log; the message points there.
escalate_apistall() {
  local name="$1" nretries="$2" errline="$3" hint=""
  [ "$name" = "orchestrator" ] && return 0
  if printf '%s' "$errline" | grep -qi 'content filter'; then
    hint=" This looks like a content-filter block; a plain retry rarely clears it. Ladder: split the unit into smaller chunks, delegate the blocked passage to a sub-agent writing directly to the file, or retire+respawn the owner if its context is filter-poisoned."
  fi
  tmux_submit "$TEAM_SESSION:orchestrator" "[watchdog] role '$name' has stalled on the same API error $nretries times within one episode and auto-retry is exhausted (error line in $TEAM_DIR/audit/api-watchdog/$name.log).${hint} Intervene: re-brief it around the error, re-route the unit, or retire+respawn."
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

      # --- E. USAGE-STALL path (parked on the usage-limit dialog) ------------
      # Auto-recoverable: Escape dismisses the modal, "try again" resumes the
      # aborted turn once usage returns. Retried indefinitely on a flat cadence
      # (see header); pushed to the operator ONCE on entry.
      if [ "$state" = "stalled-usage" ]; then
        if [ "$prev" != "stalled-usage" ]; then
          # A retry attempt makes the pane busy for a scan or two before the
          # dialog re-opens, so one continuous outage re-enters this path many
          # times. Keep last_retry (nudge pacing survives the blip) and dedupe
          # the operator push with a marker file: one push per role per
          # USAGE_PUSH_DEDUPE_SEC (default 3600), not one per oscillation.
          since=$nowts; retries=0
          echo "$(iso "$nowts") [$name] USAGE-STALL (usage-limit dialog; auto-retrying every ${usage_retry_sec}s)" >> "$af"
          _upf="$health_dir/$name.usage-pushed"
          _uplast=$(cat "$_upf" 2>/dev/null || echo 0)
          case "$_uplast" in ''|*[!0-9]*) _uplast=0;; esac  # truncated/garbled marker => treat as never
          if [ $((nowts - _uplast)) -ge "${USAGE_PUSH_DEDUPE_SEC:-3600}" ]; then
            notify "🟠 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' hit the usage limit; auto-retrying every ${usage_retry_sec}s until usage returns"
            echo "$nowts" > "$_upf"
          fi
        fi
        # Pace nudges via a marker file rather than last_retry: the health
        # file's counters are reset by the active/busy paths on every blip
        # between attempts, but one outage is one episode and the cadence
        # must span it.
        _unf="$health_dir/$name.usage-nudged"
        _unlast=$(cat "$_unf" 2>/dev/null || echo 0)
        case "$_unlast" in ''|*[!0-9]*) _unlast=0;; esac  # truncated/garbled marker => treat as never
        if [ $((nowts - _unlast)) -ge "$usage_retry_sec" ]; then
          # A modal swallows typed keys, so dismiss it before nudging.
          if printf '%s' "$visible" | _has_modal_dialog_text; then
            tmux send-keys -t "$wid" Escape 2>/dev/null || true
            sleep 0.4
          fi
          tmux_submit "$wid" "try again — the usage limit may have reset; resume your current unit where you left off"
          retries=$((retries + 1)); last_retry=$nowts
          echo "$nowts" > "$_unf"
          echo "$(iso "$nowts") [$name] usage-retry $retries (cadence ${usage_retry_sec}s)" >> "$af"
        fi
        persist "$hf" "stalled-usage" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
        continue
      fi

      # --- A. API-STALL path (idle at prompt with an error pattern) ----------
      if [ "$state" = "stalled-api" ]; then
        errline="$(printf '%s' "$visible" | tail -15 | grep -iE "$pattern_regex" | head -1 | sed 's/^[[:space:]]*//')"
        _aef="$health_dir/$name.api-episode"
        if [ "$prev" != "stalled-api" ] && [ "$prev" != "give-up" ]; then
          # Episode memory (marker file; see episode_window above): if the
          # previous stall/retry was within the window, this is the SAME
          # episode continuing across a busy blip — restore its counters so
          # repeated same-error stalls actually reach give-up and escalate.
          _ep="$(cat "$_aef" 2>/dev/null || echo '')"
          _ep_r="${_ep%% *}"; _ep_t="${_ep##* }"
          case "$_ep_r" in ''|*[!0-9]*) _ep_r=0;; esac
          case "$_ep_t" in ''|*[!0-9]*) _ep_t=0;; esac
          if [ "$_ep_t" -gt 0 ] && [ $((nowts - _ep_t)) -le "$episode_window" ]; then
            retries=$_ep_r; last_retry=$_ep_t
            [ "$since" -eq 0 ] && since=$nowts
            echo "$(iso "$nowts") [$name] STALLED again (episode continues at $retries retries)" >> "$af"
          else
            since=$nowts; retries=0; last_retry=0
            rm -f "$health_dir/$name.api-giveup-sent" 2>/dev/null || true
            echo "$(iso "$nowts") [$name] STALLED (api/network error)" >> "$af"
          fi
          # No operator push: the watchdog auto-retries with backoff. Only the
          # terminal give-up (retries exhausted) below pushes.
        fi
        if [ "$retries" -ge "$max_retries" ]; then
          # Terminal for this episode: push the operator AND hand the error to
          # the orchestrator (it owns the recovery ladder), ONCE per episode.
          # Marker-deduped: give-up re-enters on every busy blip, and before
          # the dedupe each re-entry restarted the retry loop from 0 instead
          # of escalating.
          _gf="$health_dir/$name.api-giveup-sent"
          if [ ! -f "$_gf" ]; then
            echo "$(iso "$nowts") [$name] GIVE-UP after $retries retries (episode window ${episode_window}s; error: ${errline:-unavailable}); asked orchestrator to intervene" >> "$af"
            notify "🔴 [orchestrator/${TEAM_RUN_ID:-legacy}] role '$name' still failing after $retries retries (${errline:-api error}); orchestrator asked to intervene"
            escalate_apistall "$name" "$retries" "$errline"
            echo "$nowts" > "$_gf"
          fi
          persist "$hf" "give-up" "$retries" "$last_retry" "$since" "$fp" "$fp_since" "$nudge_fp" "$nudge_count" "$last_nudge"
          continue
        fi
        idx="$retries"; [ "$idx" -ge "${#backoff[@]}" ] && idx=$((${#backoff[@]} - 1))
        required=${backoff[$idx]}
        elapsed=$((nowts - last_retry))
        if [ "$last_retry" -eq 0 ] || [ "$elapsed" -ge "$required" ]; then
          tmux_submit "$wid" 'try again'
          retries=$((retries + 1)); last_retry=$nowts
          echo "$retries $last_retry" > "$_aef"
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
      if [ "$prev" = "stalled-usage" ]; then
        echo "$(iso "$nowts") [$name] RECOVERED-USAGE after $retries retries (usage returned)" >> "$af"
        # No push: recovery is not actionable. Logged only. Keep the pacing
        # markers: idle-at-prompt scans occur BETWEEN retry attempts during a
        # still-live outage (this branch cannot tell a real recovery from
        # one), and clearing them here would defeat the dedupe on the next
        # oscillation. Stale markers only delay a brand-new outage's first
        # push/nudge by their window, which is acceptable.
        #
        # Wake the orchestrator: after a long outage every parked WORKER
        # resumes its own aborted turn via the usage path, but an orchestrator
        # that was IDLE when usage ran out has no turn to resume, so nothing
        # re-dispatched work and a recovered team sat idle until a human
        # noticed (observed: 13h overnight, 2026-07-10). One deduped nudge per
        # USAGE_WAKE_DEDUPE_SEC across the team; skipped while the
        # orchestrator is itself usage-stalled (its modal would swallow the
        # typed keys, and its own recovery path resumes it anyway). This
        # branch can fire during a still-live outage (see above), in which
        # case the nudged orchestrator just re-enters the usage path — a
        # wasted turn an hour, not a hazard.
        if [ "$name" != "orchestrator" ]; then
          _owf="$health_dir/orchestrator.usage-wake"
          _owlast=$(cat "$_owf" 2>/dev/null || echo 0)
          case "$_owlast" in ''|*[!0-9]*) _owlast=0;; esac
          _ostate="$(jq -r '.state // "unknown"' "$health_dir/orchestrator.json" 2>/dev/null)"
          if [ "$_ostate" != "stalled-usage" ] && [ $((nowts - _owlast)) -ge "${USAGE_WAKE_DEDUPE_SEC:-3600}" ]; then
            tmux_submit "$TEAM_SESSION:orchestrator" "[watchdog] role '$name' just recovered from a usage-limit stall; the usage outage may be over. Check $TEAM_DIR/health/, re-read the ledger, reconcile unit statuses against what is actually committed, and re-dispatch anything in flight."
            echo "$nowts" > "$_owf"
            echo "$(iso "$nowts") [$name] USAGE-WAKE sent to orchestrator" >> "$af"
          fi
        fi
      elif [ "$prev" = "stalled-api" ] || [ "$prev" = "give-up" ]; then
        echo "$(iso "$nowts") [$name] RECOVERED after $retries retries" >> "$af"
        # No push: recovery is not actionable. Logged only. A genuine recovery
        # (idle prompt, no error in the tail) ends the api-stall episode; a
        # false positive here (the sub-second gap between a retry submit and
        # the spinner) is rare at the scan cadence and only resets the count once.
        rm -f "$health_dir/$name.api-episode" "$health_dir/$name.api-giveup-sent" 2>/dev/null || true
      elif [ "$prev" = "stuck" ] || [ "$prev" = "stuck-giveup" ] || [ "$prev" = "stuck-giveup-esc" ]; then
        echo "$(iso "$nowts") [$name] RECOVERED-STUCK (back at prompt)" >> "$af"
        # No push: recovery is not actionable. Logged only.
      fi
      # genuinely active/idle: reset both api-stall and stuck bookkeeping.
      persist "$hf" "active" 0 0 "$nowts" "$fp" "$nowts" "" 0 0
    done
}

# Start-time canary: confirm the watchdog can actually READ a live role
# pane and recognise Claude Code chrome right now, so a tmux-access break or a CC
# UI-format change is caught at start instead of by silently mis-classifying every
# pane as healthy-idle for hours (the failure class behind the compaction probe
# going blind on the 2.1.170 upgrade). Best-effort, one shot, never blocks start.
canary() {
  if [ -z "$pattern_regex" ]; then
    echo "api-watchdog CANARY-FAIL: empty stall-pattern regex; stall detection is OFF"
    notify "🔴 [api-watchdog/${TEAM_RUN_ID:-legacy}] CANARY: no stall patterns loaded; stall detection OFF"
    return
  fi
  tmux has-session -t "$TEAM_SESSION" 2>/dev/null || { echo "api-watchdog canary: no session yet; deferred"; return; }
  # At a cold start the watchdog races the first Claude Code TUI render: the
  # session/window exists but its pane captures empty for a few seconds. A
  # one-shot read here used to declare "recovery blind" on that race even
  # though every later scan read panes fine. Retry briefly before concluding.
  local wid txt attempt
  for attempt in 1 2 3 4 5 6; do
    wid="$(tmux list-windows -t "$TEAM_SESSION" -F '#{window_id}' 2>/dev/null | head -1)"
    if [ -n "$wid" ]; then
      txt="$(tmux capture-pane -t "$wid" -p 2>/dev/null)"
      [ -n "$txt" ] && break
    fi
    [ "$attempt" = 6 ] || sleep 10
  done
  if [ -z "${wid:-}" ]; then echo "api-watchdog canary: no windows yet; deferred"; return; fi
  if [ -z "${txt:-}" ]; then
    echo "api-watchdog CANARY-FAIL: empty pane capture after $attempt attempts; cannot read role panes (recovery blind)"
    notify "🔴 [api-watchdog/${TEAM_RUN_ID:-legacy}] CANARY: cannot read role panes (tmux capture empty); recovery blind"
    return
  fi
  # Every live Claude Code pane shows the input prompt glyph or the busy
  # 'esc to interrupt' marker or the permission-mode footer. None of them = the
  # chrome the detectors parse has changed.
  if printf '%s' "$txt" | grep -qE '❯|esc to interrupt|bypass permissions'; then
    echo "api-watchdog canary: pane readable, Claude Code chrome recognised (ok)"
  else
    echo "api-watchdog CANARY-WARN: pane readable but no recognised Claude Code chrome (UI format may have changed)"
    notify "🟠 [api-watchdog/${TEAM_RUN_ID:-legacy}] CANARY: role pane shows no recognised Claude Code chrome; busy/stall detection may be blind"
  fi
}

echo "api-watchdog: starting team=$TEAM_SESSION run=${TEAM_RUN_ID:-legacy} interval=${interval}s max-retries=$max_retries stuck=$([ "$stuck_disabled" = 1 ] && echo off || echo "${stuck_threshold}s/${stuck_max_nudges}nudges") await=$([ "$await_disabled" = 1 ] && echo off || echo "${await_operator_sec}s") ntfy=${NTFY_URL:-<unset>}"
if [ "$once" = 1 ]; then
  scan_once; exit 0
fi
canary
trap 'echo "api-watchdog: stopping"; exit 0' TERM INT
while true; do
  scan_once
  # Reload if this daemon's own source changed on disk (debounced + bash -n gated).
  self_reload_check "$0" ${_SR_ORIG_ARGS[@]+"${_SR_ORIG_ARGS[@]}"}
  sleep "$interval"
done

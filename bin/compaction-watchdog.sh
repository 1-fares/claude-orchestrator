#!/usr/bin/env bash
# compaction-watchdog.sh: keep team sessions' context off the auto-compact ceiling
# by compacting them EARLY, at a task boundary, instead of letting Claude Code wait
# until a session is near the window limit.
#
# Why: Claude Code only auto-compacts a session when its context approaches the
# window limit (~95% of 1M). A near-full window is the most expensive state to run
# in: every turn re-reads a very large cached context. Compacting early, while a
# session is idle between tasks, keeps the run in a small, cheap context for most
# of its life. A session re-reads its ledger/state/role after a compaction, so no
# working knowledge is lost.
#
# MULTI-TARGET (2026-06-10): this daemon originally watched ONLY the orchestrator
# (window 0). Every fable session pays ~2x an opus one per token, so the
# cheap-context discipline pays double on the fable workers — and a wedged worker
# at the ceiling is as costly as a wedged orchestrator. The daemon now watches
# window 0 (orchestrator) ALWAYS, plus every other window whose role runs fable
# (per $TEAM_DIR/models/<role>). Targets are re-enumerated each cycle, so a role
# spawned, retired, or re-modelled mid-run is picked up automatically. Per-target
# state lives in bash associative arrays keyed by role name.
#
# CEILING GUARD ON EVERY WINDOW (2026-07-11): the /context probe stays limited
# to the top-tier targets above (it types keystrokes into the pane), but the
# passive ceiling-state scan (capture + grep for "Context limit reached" /
# "Compaction failed") now covers EVERY window. A default-model worker that
# slipped past both thresholds mid-turn and landed on the terminal "Compaction
# failed" state was previously invisible to this daemon: not a probe target, so
# nobody escalated it and the run stalled until a human noticed (fact-checker,
# 2026-07-11). Ceiling-only targets get the marker + orchestrator retire+respawn
# escalation, never the probe.
#
# Choosing the RIGHT moment (two thresholds, agent-cooperative first):
#   - At the per-role NUDGE pct the daemon does NOT force anything. It asks the
#     session to compact ITSELF at its next safe checkpoint (after it has written
#     its ledger/state, with no in-flight subagent). The agent knows a semantically
#     safe point better than any pane heuristic can.
#   - At the per-role FORCE pct the daemon force-sends `/compact` as a backstop,
#     with focus instructions to preserve task state. By the force pct auto-compact
#     is imminent anyway, so a controlled forced compaction is the safer of two
#     certainties.
#
# Per-role thresholds are model-aware (fable: nudge 70 / force 85; opus default
# 80 / 90). The launch records each role's model in $TEAM_DIR/models/<role>
# (team-spawn.sh); explicit COMPACT_*_PCT env always wins (global override).
#
# Both actions fire only at a genuine "good moment", per pane:
#   - pane unchanged for COMPACT_IDLE_SEC: a task boundary, and proof nothing is
#     streaming. If the operator is mid-type the pane is changing, so the daemon
#     stands down.
#   - not busy: no `esc to interrupt` (no turn in progress) in the live rows.
#   - input line empty or only dim autocomplete shadow text; real unsubmitted
#     text means someone left something queued, so skip and do not clobber it.
# It then probes context with `/context` and reads the total `(NN%)`. The /context
# keystrokes are serialized per pane (one target probed at a time within a pass).
#
# UNRECOVERABLE CEILING (compaction failed / hard limit):
#   - ORCHESTRATOR (window 0): the watchdog auto-recovers with /clear + a rebrief
#     pointing it back at state.md (the manual recovery, automated). This stays
#     ORCHESTRATOR-ONLY: the rebrief text is orchestrator-specific and the
#     orchestrator's load-bearing state is on disk.
#   - A WORKER at an unrecoverable ceiling is NOT /cleared (no worker rebrief text,
#     and the orchestrator owns retire+respawn per its role doc). Instead the
#     watchdog writes a durable marker, fires ntfy, and posts a one-time notice
#     into the orchestrator pane asking it to retire+respawn that worker.
#
# Read-only except the slash command / the one cooperative message. Never makes a
# Claude API call, so it cannot itself be rate-limited.
#
# Env:
#   COMPACT_WATCHDOG_DISABLED=1  do not run (exit 0)
#   COMPACT_NUDGE_PCT            global override: ask to self-compact at/above this
#                                (else per-role default: fable 70, opus 80)
#   COMPACT_FORCE_PCT            global override: force /compact at/above this
#                                (else per-role default: fable 85, opus 90)
#   COMPACT_THRESHOLD_PCT        legacy alias for COMPACT_NUDGE_PCT
#   COMPACT_NUDGE_DEBOUNCE=600   min seconds between two cooperative nudges (per role)
#   COMPACT_DEBOUNCE_SEC=900     min seconds between two forced compactions (per role)
#   COMPACT_CHECK_INTERVAL=180   seconds between full passes over all targets
#   COMPACT_IDLE_SEC=45          pane must be unchanged this long = task boundary
#   COMPACT_PRESERVE=<text>      focus instructions for a forced /compact
#   COMPACT_SOCKET=orchestrator  tmux -L socket name (the engine passes $TEAM_TMUX)
#   COMPACT_SESSION=<name>       team session; if unset, first orch-* on the socket
#                               (engine passes $TEAM_SESSION). Window 0 = orchestrator.
#   COMPACT_PROBE_WAIT=4         seconds to wait for /context output to render
#   COMPACT_LOG=<path>           audit log (default ${TEAM_DIR:-.}/compaction-watchdog.log)

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib/compaction-detect.sh
. "$repo/bin/lib/compaction-detect.sh"
# shellcheck source=bin/lib/tmux-submit.sh
. "$repo/bin/lib/tmux-submit.sh"

SOCK="${COMPACT_SOCKET:-orchestrator}"
SESSION="${COMPACT_SESSION:-}"
MODELS_DIR="${TEAM_DIR:-.}/models"
# Global threshold overrides (per-role defaults resolved in resolve_thresholds).
NUDGE_OVERRIDE="${COMPACT_NUDGE_PCT:-${COMPACT_THRESHOLD_PCT:-}}"
FORCE_OVERRIDE="${COMPACT_FORCE_PCT:-}"
NUDGE_DEBOUNCE="${COMPACT_NUDGE_DEBOUNCE:-600}"
DEBOUNCE="${COMPACT_DEBOUNCE_SEC:-900}"
INTERVAL="${COMPACT_CHECK_INTERVAL:-180}"
IDLE_SEC="${COMPACT_IDLE_SEC:-45}"
PROBE_WAIT="${COMPACT_PROBE_WAIT:-4}"
PRESERVE="${COMPACT_PRESERVE:-preserve the current task state, open decisions, and in-flight work}"
LOG="${COMPACT_LOG:-${TEAM_DIR:-.}/compaction-watchdog.log}"
# Ceiling guard (busy-agnostic). A near-full / wedged session renders the
# warning/limit/failed strings in its pane even while busy; the idle-gated probe
# below never sees them. We check every cycle and: force a compact on the warning
# (still compactable); on the unrecoverable ceiling/failed-compaction write a loud
# operator marker (never a silent wedge) and, for the ORCHESTRATOR only, do a
# /clear + rebrief once the state persists (the manual recovery, automated). A
# worker at the unrecoverable ceiling is escalated to the orchestrator instead.
HEALTH_DIR="${COMPACT_HEALTH_DIR:-${TEAM_DIR:-.}/health}"
# Back-compat: an explicit COMPACT_CEILING_MARKER overrides the orchestrator's
# marker path only; workers always use the per-role default.
ORCH_MARKER_OVERRIDE="${COMPACT_CEILING_MARKER:-}"
AUTORECOVER="${COMPACT_AUTORECOVER:-1}"
RECOVER_DEBOUNCE="${COMPACT_RECOVER_DEBOUNCE:-600}"
# Probe-blindness backstop: if the /context probe parses empty for
# PROBE_FAIL_ALARM consecutive cycles for a target, the watchdog is functionally
# blind for it. Two real causes seen: (a) a CC version changed the /context format;
# (b) a LARGE-context pane in fullscreen TUI mode — /context overflows the viewport
# and its total line (top) is unreachable via capture-pane (no tmux scrollback in
# the alt-screen), so there is genuinely no total to parse. A worker went blind
# this way in a live run (10 consecutive) and only survived by self-compacting. Either
# way the watchdog can no longer compact that pane early, so escalate FAST: raise a
# durable per-role marker + ntfy + nudge the pane to self-compact + tell the
# orchestrator (for a worker). Default 3 cycles (was 5) so a near-ceiling blind pane
# is flagged in ~6-9 min, not ~20.
PROBE_FAIL_ALARM="${COMPACT_PROBE_FAIL_ALARM:-3}"

[ "${COMPACT_WATCHDOG_DISABLED:-0}" = "1" ] && { echo "compaction-watchdog disabled"; exit 0; }

# Per-team singleton via an exclusive flock UNDER TEAM_DIR. The old guard was a
# global `pgrep bin/compaction-watchdog.sh` in the launchers: it could not tell
# two teams apart, so a second team's (different TEAM_DIR) watchdog was wrongly
# blocked. A per-TEAM_DIR lock scopes it correctly AND is atomic + stale-proof
# (kernel-released on death), so a duplicate -- which would double every /compact
# and /context keystroke into a pane -- exits at birth. fd 200, NOT fd 9 (the
# roster lock the daemon drops via 9>&-). The daemon then owns its pidfile.
_COMPACT_LOCK="${COMPACT_LOCK:-${TEAM_DIR:-.}/compaction-watchdog.lock}"
if command -v flock >/dev/null 2>&1 && exec 200>"$_COMPACT_LOCK"; then
  if ! flock -n 200; then
    echo "compaction-watchdog already running (lock $_COMPACT_LOCK held); exiting"; exit 0
  fi
fi
_COMPACT_PIDF="${COMPACT_PIDFILE:-${TEAM_DIR:-.}/compaction-watchdog.pid}"
echo $$ > "$_COMPACT_PIDF" 2>/dev/null || true
# On exit, also reap our children. The loop's `sleep $INTERVAL` is an external
# child that INHERITS the flock fd; a bare SIGTERM kills this bash but orphans the
# sleep (reparented to init), which keeps holding the lock for up to INTERVAL
# seconds — long enough to block compaction-watchdog-ensure.sh from relaunching
# (observed on the 2026-06-10 restart). pkill -P reaps it so the lock frees at
# once. Trap TERM/INT explicitly so the EXIT trap runs on signal, not just on a
# normal return.
_compact_cleanup() { rm -f "$_COMPACT_PIDF" 2>/dev/null; pkill -P $$ 2>/dev/null || true; }
trap _compact_cleanup EXIT
trap 'exit 0' TERM INT

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
tmux_o() { tmux -L "$SOCK" "$@"; }
# submit_o <target> <msg>: verified submit via the shared helper (double-Enter
# for [Pasted text] blocks + capture-pane check that the input line emptied).
# Replaces the hand-rolled "-l msg; Enter; sleep 1; Enter" sequences, several of
# which left long nudges sitting unsubmitted under load.
submit_o() { _tmux_submit_via tmux_o "$@"; }
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }
# Operator push (mirrors api-watchdog.sh): no-op when NTFY_URL is unset, the
# durable marker carries the signal regardless.
notify() {
  [ -z "${NTFY_URL:-}" ] && return 0
  curl -sS -m 5 -X POST -d "$1" "$NTFY_URL" -o /dev/null 2>/dev/null || true
}

# Resolve the team session name. Honor COMPACT_SESSION if set, else take the first
# orch-* session on the socket.
orch_session() {
  local s
  if [ -n "$SESSION" ]; then
    tmux_o has-session -t "$SESSION" 2>/dev/null || return 1
    printf '%s' "$SESSION"; return 0
  fi
  s="$(tmux_o list-sessions -F '#{session_name}' 2>/dev/null | grep '^orch-' | head -1)"
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}
orch_target() { local s; s="$(orch_session)" || return 1; printf '%s:0' "$s"; }

# Per-role health-marker paths. The orchestrator keeps the historical
# ceiling-orchestrator.md path (or its env override) so an external watcher that
# keys on it is unaffected.
role_marker() {
  if [ "$1" = orchestrator ] && [ -n "$ORCH_MARKER_OVERRIDE" ]; then
    printf '%s' "$ORCH_MARKER_OVERRIDE"
  else
    printf '%s/ceiling-%s.md' "$HEALTH_DIR" "$1"
  fi
}
role_blind_marker() { printf '%s/compaction-probe-blind-%s.md' "$HEALTH_DIR" "$1"; }

# resolve_thresholds <role>: set NUDGE_R / FORCE_R for the role's model. Global
# env override wins; else fable -> 70/85, anything else (opus) -> 80/90.
resolve_thresholds() {
  local role="$1" dn=80 df=90
  if grep -qs '^fable' "$MODELS_DIR/$role" 2>/dev/null; then dn=70; df=85; fi
  NUDGE_R="${NUDGE_OVERRIDE:-$dn}"
  FORCE_R="${FORCE_OVERRIDE:-$df}"
}

# enumerate_targets: echo "<role> <target> <orchflag> <probeflag>" lines, one per
# window. The window NAME is the role name. orchflag=1 for window 0 (the
# orchestrator, autorecover-eligible), 0 otherwise. probeflag=1 (window 0 plus
# every fable-model role per $TEAM_DIR/models/<role>) = full watch including the
# /context probe; probeflag=0 (every other window) = ceiling guard ONLY. The
# probe types keystrokes into the pane, so it stays limited to the panes whose
# token cost justifies early compaction — but the ceiling guard is a passive
# capture+grep, and a default-model worker wedged at the unrecoverable ceiling
# was invisible while only probe targets were enumerated (a worker hit
# "Compaction failed" and nothing escalated, 2026-07-11).
enumerate_targets() {
  local sess wins line widx wname oldifs
  sess="$(orch_session)" || return 1
  wins="$(tmux_o list-windows -t "$sess" -F '#{window_index} #{window_name}' 2>/dev/null)"
  [ -n "$wins" ] || return 1
  # Iterate with an IFS-split for-loop and parse fields by parameter expansion.
  # Deliberately NO stdin redirection (no `while read ... done < <(...)` or
  # here-string): when this function runs inside a command-substitution or pipe
  # subshell, a stdin-redirected loop body races and truncates after the first
  # iteration (observed: only window 0 survives). A for-loop over a fully-captured
  # string touches no FD, so enumeration is identical whether the function is
  # called directly, redirected to a file, captured with $(...), or piped.
  oldifs="$IFS"; IFS=$'\n'
  for line in $wins; do
    widx="${line%% *}"; wname="${line#* }"
    [ -n "$wname" ] || continue
    if [ "$widx" = "0" ]; then
      printf '%s %s:%s 1 1\n' "$wname" "$sess" "$widx"
      continue
    fi
    if grep -qs '^fable' "$MODELS_DIR/$wname" 2>/dev/null; then
      printf '%s %s:%s 0 1\n' "$wname" "$sess" "$widx"
    else
      printf '%s %s:%s 0 0\n' "$wname" "$sess" "$widx"
    fi
  done
  IFS="$oldifs"
}

# A turn is actively in progress. "esc to interrupt" is the canonical marker, but
# some CC renders show only a spinner status line ("Working…" / "Thinking… (1m
# 16s)") or a "Press up to edit queued messages" hint (keystrokes are queueing)
# WITHOUT "esc to interrupt" in the live rows. Treat all of these as busy so a
# probe never types into a mid-turn pane — there /context queues instead of
# rendering, which parses empty and (in the canary, which skips the IDLE_SEC gate)
# raises a spurious probe-blind alarm (observed 2026-06-10). Still NOT gating on
# "still running" (the persistent bus monitor, almost always present); the
# IDLE_SEC gate already catches a changing spinner in the running loop.
is_busy() {
  printf '%s' "$1" | tail -n 8 | grep -qiE 'esc to interrupt|working(…|\.\.\.)|thinking(…|\.\.\.)|press up to edit queued'
}

# Classify the input line: empty | shadow | real.
#   plain = ANSI-stripped pane (is there any text?)
#   etxt  = pane WITH escapes (dim/faint shadow marker \e[2m / \e[0;2m)
input_class() {
  local plain="$1" etxt="$2" stripped eline
  # Content after the last prompt char. Delete UTF-8 non-breaking space (C2 A0,
  # which Claude Code renders after the prompt and which [[:space:]] does NOT match)
  # and all ASCII whitespace, so an empty prompt reads as empty, not as "real text".
  stripped="$(printf '%s' "$plain" | grep -aE '❯' | tail -1 | sed -E 's/.*❯//' | sed $'s/\xc2\xa0//g' | tr -d '[:space:]')"
  [ -z "$stripped" ] && { echo empty; return; }
  eline="$(printf '%s' "$etxt" | grep -aE '❯' | tail -1)"
  if printf '%s' "$eline" | grep -qE $'\x1b\\[0?;?2m'; then echo shadow; else echo real; fi
}

probe_pct() {
  local t="$1"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/context" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep "$PROBE_WAIT"
  # Capture a wide window (the /context block grows near the ceiling: the warning
  # block + footer push the total line up) and parse all known formats. The total
  # moved from a parenthesised "(NN%)" to a "NN% context used" footer in 2.1.x;
  # see bin/lib/compaction-detect.sh.
  tmux_o capture-pane -t "$t" -p -S -60 2>/dev/null | parse_context_pct
}

# Cooperative: ask a session to compact itself at its own safe checkpoint.
# Plain text, no apostrophes (shell-quoting safety over send-keys).
do_nudge() {
  local t="$1" pct="$2"
  local msg="[compaction-watchdog] Context is at ${pct} percent. When you reach a safe checkpoint (ledger and state written, no in-flight subagent), please run /compact so the run stays in a cheap context. Finish the current step first; there is no rush."
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  submit_o "$t" "$msg"
}

# Backstop: force a controlled compaction with focus instructions.
do_compact() {
  local t="$1"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/compact $PRESERVE" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
}

# Last-resort recovery for the ORCHESTRATOR at the UNRECOVERABLE ceiling
# (compaction failed / hard limit): /clear, then re-brief so it rebuilds from
# disk. This is the manual recovery (forced /clear + rehydrate from state.md)
# automated. ORCHESTRATOR-ONLY: the orchestrator's load-bearing state lives in
# state.md + the ledger, so a clear is safe and the rebrief points it back at
# those rather than summarising from memory. Workers have no such rebrief and are
# escalated to the orchestrator instead (notify_orch_worker_wedged).
do_clear_rebrief() {
  local t="$1"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/clear" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep 3
  local brief="You are the orchestrator, auto-recovered from a context-limit wedge (compaction could not reduce below the limit, so the watchdog /cleared you; your state is on disk). Re-join the bus: /is c orchestrator. Then reconstruct the run from ./CLAUDE.md, ./roles/orchestrator.md, and ${TEAM_DIR:-.}/state.md (read the recent tail, including the decision-log). Resume from there; keep context lean (point to files, do not re-read everything, checkpoint+compact at task boundaries). Report status when re-oriented."
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  submit_o "$t" "$brief"
}

# Escalate a WORKER that is at the unrecoverable ceiling to the orchestrator (it
# owns retire+respawn). Post a one-time notice into the orchestrator pane, gated
# the same way as any keystroke (never type into a busy pane or over real input).
notify_orch_worker_wedged() {
  local role="$1" cstate="$2" ot oet otxt
  ot="$(orch_target)" || { log "[$role] wedge-notice: no orchestrator pane"; return; }
  oet="$(tmux_o capture-pane -e -t "$ot" -p 2>/dev/null)"
  otxt="$(printf '%s' "$oet" | strip_ansi)"
  if [ -z "$otxt" ] || is_busy "$otxt"; then log "[$role] wedge-notice deferred (orchestrator busy/empty)"; return; fi
  case "$(input_class "$otxt" "$oet")" in
    real) log "[$role] wedge-notice deferred (orchestrator has real unsubmitted input)"; return ;;
  esac
  tmux_o send-keys -t "$ot" C-u 2>/dev/null
  submit_o "$ot" "[compaction-watchdog] Worker '${role}' is at an unrecoverable context ceiling (${cstate}); compaction cannot recover it. You own retire+respawn: please retire and respawn '${role}'. Its task state is on disk / in its PR; rebrief it fresh."
}

# Write/refresh a per-role ceiling marker.
write_ceiling_marker() {
  local role="$1" cstate="$2" m; m="$(role_marker "$role")"
  mkdir -p "$(dirname "$m")" 2>/dev/null || true
  {
    echo "# Operator alert — '${role}' context pressure: ${cstate}"
    echo
    echo "_$(date -u +%Y-%m-%dT%H:%M:%SZ)_ — '${role}' pane shows '${cstate}'."
    echo "warn=near-full (watchdog forcing a compact); limit/compact-failed="
    if [ "$role" = orchestrator ]; then
      echo "unrecoverable by compaction (watchdog auto-clears+rebriefs if enabled)."
    else
      echo "unrecoverable by compaction (watchdog escalates to the orchestrator for retire+respawn)."
    fi
    echo "Attach: TEAM_RUN_ID=${TEAM_RUN_ID:-?} bin/attach.sh"
  } > "$m.tmp.$$" 2>/dev/null \
    && mv -f "$m.tmp.$$" "$m" 2>/dev/null \
    || rm -f "$m.tmp.$$" 2>/dev/null || true
}

# Raise the probe-blind alarm for a target: durable per-role marker + ntfy + a
# one-time nudge to the role's OWN pane to self-compact (a self-compact is what
# saved the blind worker in the live run) + (for a worker) a notice to the orchestrator. Two real causes:
# a CC /context format change, OR a large context whose /context total overflows
# the pane viewport in fullscreen TUI mode (unreachable via capture-pane). The
# action — the role self-compacts — is right either way.
probe_blind_alarm() {
  local role="$1" t="$2" n="$3" is_orch="${4:-0}" m; m="$(role_blind_marker "$role")"
  mkdir -p "$(dirname "$m")" 2>/dev/null || true
  {
    echo "# Operator alert — compaction probe BLIND for '${role}'"
    echo
    echo "_$(date -u +%Y-%m-%dT%H:%M:%SZ)_ — the /context probe has parsed empty for ${n} consecutive cycles."
    echo "'${role}' context % cannot be read, so EARLY compaction is OFF for it and the"
    echo "session can drift to the auto-compact ceiling unmanaged. Likely cause, either:"
    echo "  (a) a Claude Code version changed the /context format (see bin/lib/compaction-detect.sh); or"
    echo "  (b) '${role}' has a LARGE context whose /context total overflows the pane"
    echo "      viewport in fullscreen TUI mode, so the total line is unreachable via"
    echo "      capture-pane (no alt-screen scrollback); a live worker has gone blind this way."
    echo "Action: the role should /compact at a safe checkpoint; if (a), update parse_context_pct."
    echo "Attach: TEAM_RUN_ID=${TEAM_RUN_ID:-?} bin/attach.sh"
  } > "$m.tmp.$$" 2>/dev/null \
    && mv -f "$m.tmp.$$" "$m" 2>/dev/null \
    || rm -f "$m.tmp.$$" 2>/dev/null || true
  notify "🔴 [compaction-watchdog/${TEAM_RUN_ID:-legacy}] context probe blind ${n} cycles for '${role}'; early compaction OFF (CC format change OR large-context viewport overflow). See $m"
  # Nudge the role's OWN pane to self-compact.
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  submit_o "$t" "[compaction-watchdog] I cannot read your context percentage (either the /context format changed, or your context is large enough that the /context total scrolls off the pane), so I cannot compact you early. Please /compact at a safe checkpoint, and flag the probe parser if the format changed."
  # For a WORKER, also tell the orchestrator (it can prompt a compact or retire+respawn).
  if [ "$is_orch" != "1" ]; then
    local ot oet otxt; ot="$(orch_target)" || return 0
    oet="$(tmux_o capture-pane -e -t "$ot" -p 2>/dev/null)"; otxt="$(printf '%s' "$oet" | strip_ansi)"
    if [ -z "$otxt" ] || is_busy "$otxt"; then return 0; fi
    case "$(input_class "$otxt" "$oet")" in real) return 0 ;; esac
    tmux_o send-keys -t "$ot" C-u 2>/dev/null
    submit_o "$ot" "[compaction-watchdog] Worker '${role}' is probe-blind (${n} cycles): I cannot read its context % to compact it early (likely a large context overflowing /context in fullscreen TUI). It risks drifting to the auto-compact ceiling unmanaged — consider prompting it to /compact, or retire+respawn if it wedges."
  fi
}

# Per-role state (associative arrays keyed by role name).
declare -A last_fp fp_since last_compact last_nudge last_recover ceiling_seen probe_fail probe_blind_alarmed

# process_target <role> <target> <orchflag> <probeflag>: one pass of the watch
# logic for a single pane. probeflag=0 = ceiling guard only, no /context probe.
# Returns immediately (no sleep); the caller sleeps once per pass.
process_target() {
  local role="$1" t="$2" is_orch="$3" probe="${4:-1}"
  local etxt txt fp nowt cstate idle pct m
  etxt="$(tmux_o capture-pane -e -t "$t" -p 2>/dev/null)"
  txt="$(printf '%s' "$etxt" | strip_ansi)"
  [ -n "$txt" ] || return
  fp="$(printf '%s' "$txt" | md5sum | cut -d' ' -f1)"
  nowt=$(date +%s)
  resolve_thresholds "$role"

  # --- Ceiling guard: EVERY pass, busy or idle (the probe path below is idle-
  # gated and never catches a busy session climbing to the wall). ---
  cstate="$(printf '%s' "$txt" | _ceiling_state)"
  if [ -n "$cstate" ]; then
    write_ceiling_marker "$role" "$cstate"
    case "$cstate" in
      warn)
        ceiling_seen[$role]=0
        if [ $(( nowt - ${last_compact[$role]:-0} )) -ge "$DEBOUNCE" ]; then
          log "[$role] CEILING-WARN: near-full warning on pane (busy-agnostic); forcing /compact"
          do_compact "$t"; last_compact[$role]=$nowt
        else
          log "[$role] CEILING-WARN: near-full warning (within ${DEBOUNCE}s compact debounce; marker written)"
        fi ;;
      limit|compact-failed)
        ceiling_seen[$role]=$(( ${ceiling_seen[$role]:-0} + 1 ))
        if [ "$is_orch" = "1" ]; then
          if [ "$AUTORECOVER" = 1 ] && [ "${ceiling_seen[$role]}" -ge 2 ] && [ $(( nowt - ${last_recover[$role]:-0} )) -ge "$RECOVER_DEBOUNCE" ]; then
            log "[$role] CEILING-RECOVER: ${cstate} persisted ${ceiling_seen[$role]} checks; /clear + rebrief from state.md"
            do_clear_rebrief "$t"; last_recover[$role]=$nowt; ceiling_seen[$role]=0
          else
            log "[$role] CEILING-ALERT: ${cstate} (orchestrator; marker written; autorecover=${AUTORECOVER}, seen=${ceiling_seen[$role]})"
          fi
        else
          # Worker: NO autorecover. Escalate to the orchestrator (retire+respawn).
          if [ "${ceiling_seen[$role]}" -ge 2 ] && [ $(( nowt - ${last_recover[$role]:-0} )) -ge "$RECOVER_DEBOUNCE" ]; then
            log "[$role] CEILING-WEDGE: ${cstate} persisted ${ceiling_seen[$role]} checks; escalating to orchestrator (retire+respawn) + ntfy"
            notify "🔴 [compaction-watchdog/${TEAM_RUN_ID:-legacy}] worker '${role}' at unrecoverable context ceiling (${cstate}); orchestrator should retire+respawn. Marker: $(role_marker "$role")"
            notify_orch_worker_wedged "$role" "$cstate"
            last_recover[$role]=$nowt; ceiling_seen[$role]=0
          else
            log "[$role] CEILING-ALERT: ${cstate} (worker; marker written; seen=${ceiling_seen[$role]})"
          fi
        fi ;;
    esac
    last_fp[$role]=""   # our action will change the pane; rebaseline next pass
    return
  fi
  # healthy pane -> clear a stale ceiling marker
  m="$(role_marker "$role")"
  if [ -f "$m" ]; then rm -f "$m" 2>/dev/null || true; ceiling_seen[$role]=0; log "[$role] CEILING-CLEARED: pane healthy again"; fi

  # Ceiling-guard-only target (default-model worker): no /context probe.
  [ "$probe" = 1 ] || return

  if [ "$fp" != "${last_fp[$role]:-}" ]; then last_fp[$role]="$fp"; fp_since[$role]=$nowt; return; fi
  idle=$(( nowt - ${fp_since[$role]:-$nowt} ))
  [ "$idle" -lt "$IDLE_SEC" ] && return
  is_busy "$txt" && return
  case "$(input_class "$txt" "$etxt")" in
    real) log "[$role] skip: real unsubmitted text on input line"; return ;;
  esac

  pct="$(probe_pct "$t")"
  last_fp[$role]=""   # /context changed the pane; force a fresh baseline next pass
  if [ -z "$pct" ]; then
    probe_fail[$role]=$(( ${probe_fail[$role]:-0} + 1 ))
    log "[$role] probe: could not read context % (${probe_fail[$role]} consecutive)"
    if [ "${probe_fail[$role]}" -ge "$PROBE_FAIL_ALARM" ] && [ "${probe_blind_alarmed[$role]:-0}" = 0 ]; then
      log "[$role] PROBE-BLIND: ${probe_fail[$role]} consecutive parse failures; alarming + marker (CC /context format may have changed)"
      probe_blind_alarm "$role" "$t" "${probe_fail[$role]}" "$is_orch"
      probe_blind_alarmed[$role]=1
    fi
    return
  fi
  # A real read: clear any standing blind alarm and reset the streak.
  if [ "${probe_blind_alarmed[$role]:-0}" = 1 ]; then
    rm -f "$(role_blind_marker "$role")" 2>/dev/null || true
    log "[$role] PROBE-RECOVERED: read ${pct}% again; cleared blind marker"
  fi
  probe_fail[$role]=0; probe_blind_alarmed[$role]=0

  if [ "$pct" -ge "$FORCE_R" ]; then
    if [ $(( nowt - ${last_compact[$role]:-0} )) -ge "$DEBOUNCE" ]; then
      log "[$role] FORCE: context ${pct}% >= ${FORCE_R}% after ${idle}s idle (preserve: ${PRESERVE})"
      do_compact "$t"; last_compact[$role]=$(date +%s)
    else
      log "[$role] force-suppressed: context ${pct}% (within ${DEBOUNCE}s force debounce)"
    fi
  elif [ "$pct" -ge "$NUDGE_R" ]; then
    if [ $(( nowt - ${last_nudge[$role]:-0} )) -ge "$NUDGE_DEBOUNCE" ] && [ $(( nowt - ${last_compact[$role]:-0} )) -ge "$NUDGE_DEBOUNCE" ]; then
      log "[$role] NUDGE: context ${pct}% >= ${NUDGE_R}% after ${idle}s idle (ask session to self-compact)"
      do_nudge "$t" "$pct"; last_nudge[$role]=$(date +%s)
    else
      log "[$role] nudge-suppressed: context ${pct}% (within ${NUDGE_DEBOUNCE}s nudge debounce)"
    fi
  else
    log "[$role] ok: context ${pct}% < ${NUDGE_R}% after ${idle}s idle"
  fi
}

# Start-time canary: prove the probe can read a % from a real pane right
# now, so a format break is caught at (re)start instead of after hours of silent
# blindness. Probes the orchestrator (the /context format is CC-version-global,
# not per-pane, so one pane validates the parser). Skips cleanly if the
# orchestrator is busy or absent; the running consecutive-failure backstop covers
# every target individually.
canary() {
  local t etxt txt pct
  t="$(orch_target)" || { log "canary: no orch session yet; deferred to running backstop"; return; }
  etxt="$(tmux_o capture-pane -e -t "$t" -p 2>/dev/null)"
  txt="$(printf '%s' "$etxt" | strip_ansi)"
  if [ -z "$txt" ]; then log "canary: empty pane capture; deferred"; return; fi
  if is_busy "$txt"; then log "canary: orchestrator busy; deferred to running backstop"; return; fi
  pct="$(probe_pct "$t")"
  last_fp[orchestrator]=""   # the canary's /context changed the pane; force a fresh baseline
  if [ -z "$pct" ]; then
    log "CANARY-FAIL: probe parsed empty on a live pane at startup — CC /context format may have changed (parser blind). Raising alarm."
    probe_blind_alarm "orchestrator" "$t" 0 1
  else
    log "canary: probe healthy at startup (read ${pct}%)"
  fi
}

# Start-line: enumerate the watched targets + their resolved thresholds. Use the
# redirect-to-file pattern (not a pipe) so the listing is complete; see
# enumerate_targets on why a piped/command-sub call can truncate.
start_targets=""
_st_tmp="${TEAM_DIR:-.}/.compaction-start.$$"
if enumerate_targets > "$_st_tmp" 2>/dev/null; then
  while read -r r _ orchf probef; do
    [ -n "$r" ] || continue
    if [ "${probef:-1}" = 1 ]; then
      resolve_thresholds "$r"
      start_targets+="${r}(${NUDGE_R}/${FORCE_R}$([ "$orchf" = 1 ] && echo ,orch)) "
    else
      start_targets+="${r}(ceiling-only) "
    fi
  done < "$_st_tmp"
fi
rm -f "$_st_tmp" 2>/dev/null
log "start: multi-target watching: ${start_targets:-<none yet>}| idle=${IDLE_SEC}s interval=${INTERVAL}s nudge_debounce=${NUDGE_DEBOUNCE}s force_debounce=${DEBOUNCE}s ceiling-guard=on autorecover=${AUTORECOVER}(orch-only) probe-blind-alarm=${PROBE_FAIL_ALARM} sock=${SOCK} session=${SESSION:-auto}"
canary

while :; do
  if ! enumerate_targets > "${TEAM_DIR:-.}/.compaction-targets.$$" 2>/dev/null || [ ! -s "${TEAM_DIR:-.}/.compaction-targets.$$" ]; then
    log "no targets on socket $SOCK (no orch session?)"; rm -f "${TEAM_DIR:-.}/.compaction-targets.$$" 2>/dev/null
    sleep "$INTERVAL"; continue
  fi
  while read -r role target orchflag probeflag; do
    [ -n "$role" ] || continue
    process_target "$role" "$target" "$orchflag" "$probeflag"
  done < "${TEAM_DIR:-.}/.compaction-targets.$$"
  rm -f "${TEAM_DIR:-.}/.compaction-targets.$$" 2>/dev/null
  sleep "$INTERVAL"
done

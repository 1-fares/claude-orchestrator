#!/usr/bin/env bash
# compaction-watchdog.sh: keep the orchestrator's context off the auto-compact
# ceiling by compacting it EARLY, at a task boundary, instead of letting Claude
# Code wait until it is near the window limit.
#
# Why: Claude Code only auto-compacts a session when its context approaches the
# window limit (~95% of 1M). A near-full window is the most expensive state to run
# in: every turn re-reads a very large cached context. Compacting early, while the
# orchestrator is idle between tasks, keeps the run in a small, cheap context for
# most of its life. The orchestrator re-reads its ledger/state after a compaction,
# so no working knowledge is lost.
#
# Choosing the RIGHT moment (two thresholds, agent-cooperative first):
#   - At COMPACT_NUDGE_PCT (default 80) the daemon does NOT force anything. It
#     asks the orchestrator to compact ITSELF at its next safe checkpoint (after
#     it has written its ledger/state, with no in-flight subagent). The agent
#     knows a semantically safe point better than any pane heuristic can.
#   - At COMPACT_FORCE_PCT (default 90) the daemon force-sends `/compact` as a
#     backstop, with focus instructions to preserve task state. By 90% auto-compact
#     is imminent anyway, so a controlled forced compaction is the safer of two
#     certainties.
#
# Both actions fire only at a genuine "good moment":
#   - pane unchanged for COMPACT_IDLE_SEC: a task boundary, and proof nothing is
#     streaming. If the operator is mid-type the pane is changing, so the daemon
#     stands down.
#   - not busy: no `esc to interrupt` (no turn in progress) in the live rows.
#   - input line empty or only dim autocomplete shadow text; real unsubmitted
#     text means the operator left something queued, so skip and do not clobber it.
# It then probes context with `/context` and reads the total `(NN%)`.
#
# Read-only except the slash command / the one cooperative message. Never makes a
# Claude API call, so it cannot itself be rate-limited.
#
# Env:
#   COMPACT_WATCHDOG_DISABLED=1  do not run (exit 0)
#   COMPACT_NUDGE_PCT            ask the orchestrator to self-compact at/above this
#                                (default 80; 70 when the orchestrator runs fable)
#   COMPACT_FORCE_PCT            force /compact at/above this (backstop)
#                                (default 90; 85 when the orchestrator runs fable)
#   COMPACT_THRESHOLD_PCT        legacy alias for COMPACT_NUDGE_PCT
#   COMPACT_NUDGE_DEBOUNCE=600   min seconds between two cooperative nudges
#   COMPACT_DEBOUNCE_SEC=900     min seconds between two forced compactions
#   COMPACT_CHECK_INTERVAL=180   seconds between scans
#   COMPACT_IDLE_SEC=45          pane must be unchanged this long = task boundary
#   COMPACT_PRESERVE=<text>      focus instructions for a forced /compact
#   COMPACT_SOCKET=orchestrator  tmux -L socket name (the engine passes $TEAM_TMUX)
#   COMPACT_SESSION=<name>       orchestrator session; if unset, first orch-* on the
#                               socket (engine passes $TEAM_SESSION). Window 0.
#   COMPACT_PROBE_WAIT=4         seconds to wait for /context output to render
#   COMPACT_LOG=<path>           audit log (default ${TEAM_DIR:-.}/compaction-watchdog.log)

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib/compaction-detect.sh
. "$repo/bin/lib/compaction-detect.sh"

SOCK="${COMPACT_SOCKET:-orchestrator}"
SESSION="${COMPACT_SESSION:-}"
# Threshold defaults are model-aware. Every turn taken in a large window costs
# tokens proportional to the window, and a fable orchestrator pays ~2x an opus
# one per token, so on fable the cheap-context discipline pays double: compact
# earlier by default. The launch records the model in $TEAM_DIR/models/
# (team-spawn.sh); explicit COMPACT_*_PCT env always wins.
_default_nudge=80; _default_force=90
if grep -qs '^fable' "${TEAM_DIR:-.}/models/orchestrator" 2>/dev/null; then
  _default_nudge=70; _default_force=85
fi
NUDGE="${COMPACT_NUDGE_PCT:-${COMPACT_THRESHOLD_PCT:-$_default_nudge}}"
FORCE="${COMPACT_FORCE_PCT:-$_default_force}"
NUDGE_DEBOUNCE="${COMPACT_NUDGE_DEBOUNCE:-600}"
DEBOUNCE="${COMPACT_DEBOUNCE_SEC:-900}"
INTERVAL="${COMPACT_CHECK_INTERVAL:-180}"
IDLE_SEC="${COMPACT_IDLE_SEC:-45}"
PROBE_WAIT="${COMPACT_PROBE_WAIT:-4}"
PRESERVE="${COMPACT_PRESERVE:-preserve the current task state, open decisions, and in-flight work}"
LOG="${COMPACT_LOG:-${TEAM_DIR:-.}/compaction-watchdog.log}"
# Ceiling guard (busy-agnostic). A near-full / wedged orchestrator renders the
# warning/limit/failed strings in its pane even while busy; the idle-gated probe
# below never sees them. We check every cycle and: force a compact on the warning
# (still compactable), and on the unrecoverable ceiling/failed-compaction write a
# loud operator marker (so it is never a silent wedge) and, if AUTORECOVER, do a
# /clear + rebrief once the state persists (the manual recovery, automated).
MARKER="${COMPACT_CEILING_MARKER:-${TEAM_DIR:-.}/health/ceiling-orchestrator.md}"
AUTORECOVER="${COMPACT_AUTORECOVER:-1}"
RECOVER_DEBOUNCE="${COMPACT_RECOVER_DEBOUNCE:-600}"

[ "${COMPACT_WATCHDOG_DISABLED:-0}" = "1" ] && { echo "compaction-watchdog disabled"; exit 0; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
tmux_o() { tmux -L "$SOCK" "$@"; }
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }

# Resolve the orchestrator target (<session>:0). Honor COMPACT_SESSION if set,
# else take the first orch-* session on the socket.
orch_target() {
  local s
  if [ -n "$SESSION" ]; then
    tmux_o has-session -t "$SESSION" 2>/dev/null || return 1
    printf '%s:0' "$SESSION"; return 0
  fi
  s="$(tmux_o list-sessions -F '#{session_name}' 2>/dev/null | grep '^orch-' | head -1)"
  [ -n "$s" ] || return 1
  printf '%s:0' "$s"
}

# A turn is actively in progress. "esc to interrupt" is the canonical marker and
# is only on screen during a live turn. Deliberately NOT gating on "still running"
# (the orchestrator's persistent inter-session bus monitor, almost always present)
# or on spinner glyphs (they linger in scrollback; any active turn updates the
# pane, which the IDLE_SEC gate already catches).
is_busy() {
  printf '%s' "$1" | tail -n 8 | grep -qiE 'esc to interrupt'
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

# Cooperative: ask the orchestrator to compact itself at its own safe checkpoint.
# Plain text, no apostrophes (shell-quoting safety over send-keys).
do_nudge() {
  local t="$1" pct="$2"
  local msg="[compaction-watchdog] Context is at ${pct} percent. When you reach a safe checkpoint (ledger and state written, no in-flight subagent), please run /compact so the run stays in a cheap context. Finish the current step first; there is no rush."
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "$msg" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep 1
  tmux_o send-keys -t "$t" Enter 2>/dev/null   # a long line may collapse to a [Pasted text] block; second Enter submits
}

# Backstop: force a controlled compaction with focus instructions.
do_compact() {
  local t="$1"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/compact $PRESERVE" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
}

# Last-resort recovery for the UNRECOVERABLE ceiling (compaction failed / hard
# limit): /clear, then re-brief so the orchestrator rebuilds from disk. This is
# the manual recovery (forced /clear + rehydrate from state.md) automated. The
# orchestrator's load-bearing state lives in state.md + the ledger, so a clear is
# safe; the rebrief points it back at those rather than summarising from memory.
do_clear_rebrief() {
  local t="$1"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/clear" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep 3
  local brief="You are the orchestrator, auto-recovered from a context-limit wedge (compaction could not reduce below the limit, so the watchdog /cleared you; your state is on disk). Re-join the bus: /is c orchestrator. Then reconstruct the run from ./CLAUDE.md, ./roles/orchestrator.md, ${TEAM_DIR:-.}/state.md and ${TEAM_DIR:-.}/DECISIONS-FOR-FARES.md (read the recent tail). Resume from there; keep context lean (point to files, do not re-read everything, checkpoint+compact at task boundaries). Report status when re-oriented."
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "$brief" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep 1
  tmux_o send-keys -t "$t" Enter 2>/dev/null
}

last_fp=""; fp_since=0; last_compact=0; last_nudge=0; last_recover=0; ceiling_seen=0
log "start: nudge=${NUDGE}% force=${FORCE}% idle=${IDLE_SEC}s interval=${INTERVAL}s nudge_debounce=${NUDGE_DEBOUNCE}s force_debounce=${DEBOUNCE}s ceiling-guard=on autorecover=${AUTORECOVER} sock=${SOCK} session=${SESSION:-auto}"

while :; do
  t="$(orch_target)" || { log "no orch session on socket $SOCK"; sleep "$INTERVAL"; continue; }
  etxt="$(tmux_o capture-pane -e -t "$t" -p 2>/dev/null)"
  txt="$(printf '%s' "$etxt" | strip_ansi)"
  [ -n "$txt" ] || { sleep "$INTERVAL"; continue; }
  fp="$(printf '%s' "$txt" | md5sum | cut -d' ' -f1)"
  nowt=$(date +%s)

  # --- Ceiling guard: EVERY cycle, busy or idle (the probe path below is idle-
  # gated and never catches a busy orchestrator climbing to the wall). ---
  cstate="$(printf '%s' "$txt" | _ceiling_state)"
  if [ -n "$cstate" ]; then
    mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
    {
      echo "# Operator alert — orchestrator context pressure: ${cstate}"
      echo
      echo "_$(date -u +%Y-%m-%dT%H:%M:%SZ)_ — orchestrator pane shows '${cstate}'."
      echo "warn=near-full (watchdog forcing a compact); limit/compact-failed="
      echo "unrecoverable by compaction (watchdog auto-clears+rebriefs if enabled)."
      echo "Attach: TEAM_RUN_ID=${TEAM_RUN_ID:-?} bin/attach.sh"
    } > "$MARKER.tmp.$$" 2>/dev/null \
      && mv -f "$MARKER.tmp.$$" "$MARKER" 2>/dev/null \
      || rm -f "$MARKER.tmp.$$" 2>/dev/null || true
    case "$cstate" in
      warn)
        ceiling_seen=0
        if [ $(( nowt - last_compact )) -ge "$DEBOUNCE" ]; then
          log "CEILING-WARN: near-full warning on pane (busy-agnostic); forcing /compact"
          do_compact "$t"; last_compact=$nowt
        else
          log "CEILING-WARN: near-full warning (within ${DEBOUNCE}s compact debounce; marker written)"
        fi ;;
      limit|compact-failed)
        ceiling_seen=$(( ceiling_seen + 1 ))
        if [ "$AUTORECOVER" = 1 ] && [ "$ceiling_seen" -ge 2 ] && [ $(( nowt - last_recover )) -ge "$RECOVER_DEBOUNCE" ]; then
          log "CEILING-RECOVER: ${cstate} persisted ${ceiling_seen} checks; /clear + rebrief from state.md"
          do_clear_rebrief "$t"; last_recover=$nowt; ceiling_seen=0
        else
          log "CEILING-ALERT: ${cstate} (marker written; autorecover=${AUTORECOVER}, seen=${ceiling_seen})"
        fi ;;
    esac
    last_fp=""   # our action will change the pane; rebaseline next scan
    sleep "$INTERVAL"; continue
  fi
  # healthy pane -> clear a stale ceiling marker
  if [ -f "$MARKER" ]; then rm -f "$MARKER" 2>/dev/null || true; ceiling_seen=0; log "CEILING-CLEARED: pane healthy again"; fi

  if [ "$fp" != "$last_fp" ]; then last_fp="$fp"; fp_since=$nowt; sleep "$INTERVAL"; continue; fi
  idle=$(( nowt - fp_since ))
  [ "$idle" -lt "$IDLE_SEC" ] && { sleep "$INTERVAL"; continue; }
  is_busy "$txt" && { sleep "$INTERVAL"; continue; }
  case "$(input_class "$txt" "$etxt")" in
    real) log "skip: real unsubmitted text on input line"; sleep "$INTERVAL"; continue ;;
  esac

  pct="$(probe_pct "$t")"
  last_fp=""   # /context changed the pane; force a fresh baseline next scan
  if [ -z "$pct" ]; then log "probe: could not read context %"; sleep "$INTERVAL"; continue; fi

  if [ "$pct" -ge "$FORCE" ]; then
    if [ $(( nowt - last_compact )) -ge "$DEBOUNCE" ]; then
      log "FORCE: context ${pct}% >= ${FORCE}% after ${idle}s idle (preserve: ${PRESERVE})"
      do_compact "$t"; last_compact=$(date +%s)
    else
      log "force-suppressed: context ${pct}% (within ${DEBOUNCE}s force debounce)"
    fi
  elif [ "$pct" -ge "$NUDGE" ]; then
    if [ $(( nowt - last_nudge )) -ge "$NUDGE_DEBOUNCE" ] && [ $(( nowt - last_compact )) -ge "$NUDGE_DEBOUNCE" ]; then
      log "NUDGE: context ${pct}% >= ${NUDGE}% after ${idle}s idle (ask orchestrator to self-compact)"
      do_nudge "$t" "$pct"; last_nudge=$(date +%s)
    else
      log "nudge-suppressed: context ${pct}% (within ${NUDGE_DEBOUNCE}s nudge debounce)"
    fi
  else
    log "ok: context ${pct}% < ${NUDGE}% after ${idle}s idle"
  fi
  sleep "$INTERVAL"
done

#!/usr/bin/env bash
# compaction-watchdog.sh: keep the orchestrator's context off the auto-compact
# ceiling by compacting it EARLY, at a task boundary, instead of letting Claude
# Code wait until it is near the window limit.
#
# Why: Claude Code only auto-compacts when context approaches the window limit
# (~95% of 1M). A near-full window is the most expensive state to run in: every
# turn re-reads a very large cached context. Compacting early, while the
# orchestrator is idle between tasks, keeps the run in a small, cheap context for
# most of its life. The orchestrator re-reads its ledger/state after a compaction,
# so no working knowledge is lost.
#
# Per scan:
#   1. Find the live orchestrator window (tmux -L <socket>, first orch-* session,
#      window 0).
#   2. Act only at a "good moment":
#        - pane unchanged for >= IDLE_SEC: a task boundary, and proof nothing is
#          streaming (a streaming pane changes every scan). It also means that if
#          the operator is actively typing, the daemon stands down (the pane is
#          changing, so it is never "idle").
#        - not busy: no "esc to interrupt", running monitor/subagent, or spinner
#          in the live bottom rows.
#        - input line is empty OR shows only autocomplete shadow text (dim). Real
#          unsubmitted text (not dim) means the operator left something queued, so
#          skip and do not clobber it.
#   3. Probe context with `/context`, read back the total "(NN%)".
#   4. If NN% >= THRESHOLD_PCT, send `/compact`, then hold off for DEBOUNCE_SEC.
#
# Read-only except for the two slash commands. Never makes a Claude API call, so
# it cannot itself be rate-limited.
#
# Env:
#   COMPACT_WATCHDOG_DISABLED=1  do not run (exit 0)
#   COMPACT_THRESHOLD_PCT=70     compact at/above this context %
#   COMPACT_CHECK_INTERVAL=180   seconds between scans
#   COMPACT_IDLE_SEC=45          pane must be unchanged this long = task boundary
#   COMPACT_DEBOUNCE_SEC=900     minimum seconds between two compactions
#   COMPACT_SOCKET=orchestrator  tmux -L socket name (the engine passes $TEAM_TMUX)
#   COMPACT_SESSION=<name>       orchestrator session name; if unset, the first
#                               orch-* session on the socket is used (engine passes
#                               $TEAM_SESSION). Window 0 is the orchestrator.
#   COMPACT_PROBE_WAIT=4         seconds to wait for /context output to render
#   COMPACT_LOG=<path>           audit log (default ${TEAM_DIR:-.}/compaction-watchdog.log)

set -uo pipefail

SOCK="${COMPACT_SOCKET:-orchestrator}"
SESSION="${COMPACT_SESSION:-}"
THRESH="${COMPACT_THRESHOLD_PCT:-70}"
INTERVAL="${COMPACT_CHECK_INTERVAL:-180}"
IDLE_SEC="${COMPACT_IDLE_SEC:-45}"
DEBOUNCE="${COMPACT_DEBOUNCE_SEC:-900}"
PROBE_WAIT="${COMPACT_PROBE_WAIT:-4}"
LOG="${COMPACT_LOG:-${TEAM_DIR:-.}/compaction-watchdog.log}"

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
# is only on screen during a live turn. Deliberately NOT gating on "still
# running" (the orchestrator's persistent inter-session bus monitor, almost
# always present) or on spinner glyphs (they linger in scrollback and any truly
# active turn updates the pane, which the IDLE_SEC gate already catches).
is_busy() {
  printf '%s' "$1" | tail -n 8 | grep -qiE 'esc to interrupt'
}

# Classify the input line: empty | shadow | real.
#   plain = ANSI-stripped pane (for "is there any text?")
#   etxt  = pane WITH escapes (for the dim/faint shadow marker \e[2m / \e[0;2m)
input_class() {
  local plain="$1" etxt="$2" content eline
  content="$(printf '%s' "$plain" | grep -aE '❯' | tail -1 | sed -E 's/.*❯[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$content" ] && { echo empty; return; }
  eline="$(printf '%s' "$etxt" | grep -aE '❯' | tail -1)"
  if printf '%s' "$eline" | grep -qE $'\x1b\\[0?;?2m'; then echo shadow; else echo real; fi
}

probe_pct() {
  local t="$1" out pct
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/context" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep "$PROBE_WAIT"
  out="$(tmux_o capture-pane -t "$t" -p -S -40 2>/dev/null)"
  # First "(NN%)" in /context output is the total tokens line, e.g.
  # "931.6k/1m tokens (93%)". Sub-category lines are decimals like "(0.2%)"
  # and do not match the integer-only pattern.
  pct="$(printf '%s' "$out" | grep -oE '\([0-9]+%\)' | head -1 | grep -oE '[0-9]+')"
  printf '%s' "$pct"
}

do_compact() {
  local t="$1"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/compact" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
}

last_fp=""; fp_since=0; last_compact=0
log "start: thresh=${THRESH}% interval=${INTERVAL}s idle=${IDLE_SEC}s debounce=${DEBOUNCE}s sock=${SOCK}"

while :; do
  t="$(orch_target)" || { log "no orch-* session on socket $SOCK"; sleep "$INTERVAL"; continue; }
  etxt="$(tmux_o capture-pane -e -t "$t" -p 2>/dev/null)"
  txt="$(printf '%s' "$etxt" | strip_ansi)"
  [ -n "$txt" ] || { sleep "$INTERVAL"; continue; }
  fp="$(printf '%s' "$txt" | md5sum | cut -d' ' -f1)"
  nowt=$(date +%s)

  if [ "$fp" != "$last_fp" ]; then last_fp="$fp"; fp_since=$nowt; sleep "$INTERVAL"; continue; fi
  idle=$(( nowt - fp_since ))
  [ "$idle" -lt "$IDLE_SEC" ] && { sleep "$INTERVAL"; continue; }
  is_busy "$txt" && { sleep "$INTERVAL"; continue; }

  case "$(input_class "$txt" "$etxt")" in
    real)   log "skip: real unsubmitted text on input line"; sleep "$INTERVAL"; continue ;;
  esac
  if [ $(( nowt - last_compact )) -lt "$DEBOUNCE" ]; then sleep "$INTERVAL"; continue; fi

  pct="$(probe_pct "$t")"
  last_fp=""   # /context changed the pane; force a fresh baseline next scan
  if [ -z "$pct" ]; then log "probe: could not read context %"; sleep "$INTERVAL"; continue; fi
  if [ "$pct" -ge "$THRESH" ]; then
    log "COMPACT: context ${pct}% >= ${THRESH}% after ${idle}s idle"
    do_compact "$t"
    last_compact=$(date +%s)
  else
    log "ok: context ${pct}% < ${THRESH}% after ${idle}s idle"
  fi
  sleep "$INTERVAL"
done

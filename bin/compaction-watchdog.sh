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
#   COMPACT_FORCE_ESCALATE=3     forced /compact attempts that leave the pane near-full
#                                before CEILING-STUCK: ntfy + status hook, once per episode.
#                                (2026-09-01: five forces over 66 minutes, nobody told.)
#   COMPACT_CHECK_INTERVAL=180   seconds between full passes over all targets
#   COMPACT_IDLE_SEC=45          pane must be unchanged this long = task boundary
#   COMPACT_PRESERVE=<text>      focus instructions for a forced /compact
#   COMPACT_SOCKET=orchestrator  tmux -L socket name (the engine passes $TEAM_TMUX)
#   COMPACT_SESSION=<name>       team session; if unset, first orch-* on the socket
#                               (engine passes $TEAM_SESSION). Window 0 = orchestrator.
#   COMPACT_PROBE_WAIT=4         seconds to wait for /context output to render
#   COMPACT_LOG=<path>           audit log (default ${TEAM_DIR:-.}/compaction-watchdog.log)
#   COMPACT_SETTINGS_FILE=<path> Claude Code settings read for autoCompactWindow
#                                (default ~/.claude/settings.json; read on every probe)

set -uo pipefail
# Original invocation args, captured before any parsing, so self-reload can re-exec
# this daemon with the same flags (bin/lib/self-reload.sh).
_SR_ORIG_ARGS=("$@")

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/lib/compaction-detect.sh
. "$repo/bin/lib/compaction-detect.sh"
# shellcheck source=bin/lib/tmux-submit.sh
. "$repo/bin/lib/tmux-submit.sh"
# shellcheck source=bin/lib/status-hook.sh
. "$repo/bin/lib/status-hook.sh"
# Self-reload: re-exec when this file or a lib it sources changes on disk, so a synced
# fix takes effect without a restart. 2026-09-02: this daemon kept running 24 August
# code for nine hours after the fix landed, because only api-watchdog reloaded itself.
# shellcheck source=bin/lib/self-reload.sh
. "$repo/bin/lib/self-reload.sh" "$repo/bin/lib/notify.sh"
self_reload_init "$0" "$repo/bin/lib/compaction-detect.sh" "$repo/bin/lib/tmux-submit.sh" "$repo/bin/lib/tmux-input.sh" "$repo/bin/lib/status-hook.sh" "$repo/bin/lib/self-reload.sh" "$repo/bin/lib/notify.sh"

SOCK="${COMPACT_SOCKET:-orchestrator}"
SESSION="${COMPACT_SESSION:-}"
MODELS_DIR="${TEAM_DIR:-.}/models"
# Global threshold overrides (per-role defaults resolved in resolve_thresholds).
NUDGE_OVERRIDE="${COMPACT_NUDGE_PCT:-${COMPACT_THRESHOLD_PCT:-}}"
FORCE_OVERRIDE="${COMPACT_FORCE_PCT:-}"
NUDGE_DEBOUNCE="${COMPACT_NUDGE_DEBOUNCE:-600}"
DEBOUNCE="${COMPACT_DEBOUNCE_SEC:-900}"
FORCE_ESCALATE="${COMPACT_FORCE_ESCALATE:-3}"
INTERVAL="${COMPACT_CHECK_INTERVAL:-180}"
IDLE_SEC="${COMPACT_IDLE_SEC:-45}"
PROBE_WAIT="${COMPACT_PROBE_WAIT:-4}"
PRESERVE="${COMPACT_PRESERVE:-preserve verbatim the standing rules card (RULES-IN-FORCE.md) if present and the state.md unit table, then the current task state, open decisions and in-flight work}"
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
# That alarm is ONE-SHOT per blind episode: a pane that stays blind for hours is
# compacted once (which can be refused, e.g. at a usage limit) and then never again,
# and nobody is told. While a worker stays blind the orchestrator gets a bus line at
# the PROBE_FAIL_ALARM-th cycle and every BLIND_BUS_EVERY cycles after; 0 turns it off.
BLIND_BUS_EVERY="${COMPACT_BLIND_BUS_EVERY:-10}"
BUS_SEND="${COMPACT_BUS_SEND:-$repo/bin/bus-send.py}"
BUS_TIMEOUT="${COMPACT_BUS_TIMEOUT:-15}"
# Tests: COMPACT_BUS_SINK=<file> writes the line there instead of the bus (like
# NOTIFY_SINK). Without a sink a REAL send also needs $TEAM_DIR/state.md, which only a
# live team has, so a suite that runs this daemon against a mktemp TEAM_DIR can never
# put a line on a live bus.
BUS_SINK="${COMPACT_BUS_SINK:-}"
# How much of a transcript's end the jsonl probe reads (see probe_pct_from_jsonl).
JSONL_TAIL_BYTES="${COMPACT_JSONL_TAIL_BYTES:-4194304}"

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
# Every line this daemon types goes through bin/lib/tmux-input.sh (sourced by tmux-submit.sh): force INSERT, confirm,
# submit. Its direct ti_send calls reach tmux through tmux_o. A blind recipe runs only where ti_send finds no input box
# in a pane that is positively a shell (exit 2).
TI_VIA=tmux_o
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }
# Operator push (mirrors api-watchdog.sh): no-op when NTFY_URL is unset, the
# durable marker carries the signal regardless.
# 2026-09-07: the phone is reached only through bin/lib/notify.sh (classes, mute,
# dedupe, digest, audit). The old one-argument form is kept; notify_legacy maps
# 🔴 to action and everything else to info. Declare page/action explicitly for the
# few sites that need a human now: see docs/OPERATOR-PAGING.md.
# shellcheck disable=SC1091
. "$repo/bin/lib/notify.sh"
NOTIFY_SOURCE=compaction-watchdog
notify() { notify_legacy "$@"; }

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

# The base the transcript usage is measured against (tokens).
JSONL_WINDOW=200000

# role_model <role>: the model recorded for the role ($MODELS_DIR/<role>, first line), or nothing.
role_model() { head -1 "$MODELS_DIR/${1:-}" 2>/dev/null | tr -d '[:space:]'; }

# autocompact_window <model>: echo the auto-compact window Claude Code is configured
# with for that model, in TOKENS, or nothing when none is set. Reads
# $COMPACT_SETTINGS_FILE (default ~/.claude/settings.json): the per-model key
# modelSettings.<model>.autoCompactWindow first, then the top-level
# autoCompactWindow. A missing file, bad JSON or a non-positive value echoes nothing.
#
# WHY. With an autoCompactWindow set below the model window, Claude Code compacts on
# its own near that window. NUDGE/FORCE measured against a larger base then never
# fire first, and the idle-boundary compaction this daemon exists for never happens.
# The settings file is read on every call, not once at start, so a later change to
# the window takes effect without a restart.
autocompact_window() {
  local model="${1:-}" f="${COMPACT_SETTINGS_FILE:-$HOME/.claude/settings.json}"
  [ -f "$f" ] || return 0
  python3 - "$f" "$model" <<'ACPY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
def pos(v):
    return isinstance(v, int) and not isinstance(v, bool) and v > 0
ms = d.get("modelSettings") if isinstance(d, dict) else None
per = ms.get(sys.argv[2]) if isinstance(ms, dict) and sys.argv[2] else None
v = per.get("autoCompactWindow") if isinstance(per, dict) else None
if not pos(v):
    v = d.get("autoCompactWindow") if isinstance(d, dict) else None
if pos(v):
    print(v)
ACPY
}

# jsonl_window <role>: echo the base the transcript usage is measured against: the
# smaller of JSONL_WINDOW and the role's configured auto-compact window. The setting
# can only LOWER it, never raise it. Logs `effective-window ...` once per role and
# again whenever the value changes (marker file, because callers run it inside a
# command substitution).
jsonl_window() {
  local role="${1:-}" model ac ew mk line
  model="$(role_model "$role")"
  ac="$(autocompact_window "$model")"
  ew="$JSONL_WINDOW"
  if [ -n "$ac" ] && [ "$ac" -lt "$ew" ] 2>/dev/null; then ew="$ac"; fi
  line="model=${model:-<none>} base=$JSONL_WINDOW autocompact=${ac:-<unset>} effective=$ew"
  mk="$HEALTH_DIR/effective-window-${role:-none}"
  if [ "$(cat "$mk" 2>/dev/null)" != "$line" ]; then
    mkdir -p "$HEALTH_DIR" 2>/dev/null || true
    printf '%s' "$line" > "$mk" 2>/dev/null || true
    log "effective-window role=${role:-<none>} $line"
  fi
  printf '%s' "$ew"
}

# context_denominator: stdin = /context pane text -> the window the total line is
# printed against, in TOKENS ("42.1k/500k tokens (8%)" -> 500000, "/1m" -> 1000000),
# or nothing when no total line is on the pane.
context_denominator() {
  grep -oiE '/[0-9.]+[kKmM] tokens \([0-9]+%\)' | tail -1 \
    | sed -E 's#^/([0-9.]+)([kKmM]).*#\1 \2#' \
    | awk '{ m = (tolower($2) == "m") ? 1000000 : 1000; printf "%d", $1 * m + 0.5 }'
}

# rescale_pct <pct> <role> [denominator]: restate a /context percentage against the
# configured auto-compact window when that is SMALLER than the window printed on the
# total line, rounded UP (compact slightly early is the safe direction). The base is
# the printed denominator, never an assumed model window: under autoCompactWindow
# 500000 Claude Code prints "42.1k/500k tokens (8%)", so that percentage is ALREADY
# of 500k and must not be scaled again. No denominator on the pane (the footer
# formats, whose base is not printed) -> the percentage is returned unchanged.
# Empty in, empty out.
rescale_pct() {
  local pct="${1:-}" role="${2:-}" den="${3:-}" ac
  [ -n "$pct" ] || return 0
  { [ -n "$role" ] && [ -n "$den" ] && [ "$den" -gt 0 ] 2>/dev/null; } || { printf '%s' "$pct"; return 0; }
  ac="$(autocompact_window "$(role_model "$role")")"
  if [ -n "$ac" ] && [ "$ac" -gt 0 ] 2>/dev/null && [ "$ac" -lt "$den" ]; then
    printf '%s' $(( (pct * den + ac - 1) / ac ))
  else
    printf '%s' "$pct"
  fi
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
  local t="$1" role="${2:-}" cap raw rc
  ti_send "$t" "/context" clear; rc=$?
  [ -n "${TI_DISCARDED:-}" ] && log "[$t] /context probe cleared typed text from the box first: [$TI_DISCARDED]"
  # Not seen submitted: whatever /context render is on screen is an old one.
  [ "$rc" = 1 ] && return 1
  if [ "$rc" = 2 ]; then
    tmux_o send-keys -t "$t" C-u 2>/dev/null
    tmux_o send-keys -t "$t" -l "/context" 2>/dev/null
    tmux_o send-keys -t "$t" Enter 2>/dev/null
  fi
  sleep "$PROBE_WAIT"
  # Capture a wide window (the /context block grows near the ceiling: the warning
  # block + footer push the total line up) and parse all known formats. The total
  # moved from a parenthesised "(NN%)" to a "NN% context used" footer in 2.1.x;
  # see bin/lib/compaction-detect.sh.
  # Given a role, the result is restated against that role's auto-compact window
  # (rescale_pct); without one (the canary only needs "parses or not") it is raw.
  cap="$(tmux_o capture-pane -t "$t" -p -S -60 2>/dev/null)"
  raw="$(printf '%s\n' "$cap" | parse_context_pct)"
  rescale_pct "$raw" "$role" "$(printf '%s\n' "$cap" | context_denominator)"
}

# pane_session <target>: prints "<sessionId> <transcript path>" for the claude in that pane (the file need not exist).
# Chain: tmux pane PID -> ~/.claude/sessions/<PID>.json -> sessionId and cwd -> ~/.claude/projects/<project>/<sid>.jsonl
# (the project directory derived from cwd the way Claude Code does; COMPACT_PROJECT_DIR overrides it).
pane_session() {
  local t="$1" pid sid proj_dir
  pid="$(tmux_o display-message -t "$t" -p '#{pane_pid}' 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  local sess_file="$HOME/.claude/sessions/${pid}.json"
  [ -f "$sess_file" ] || return 1
  read -r sid proj_dir < <(python3 -c "
import json,sys,os
d=json.load(open(sys.argv[1]))
sid=d.get('sessionId','')
cwd=d.get('cwd','')
if cwd:
    u=os.path.expanduser('~')
    slug=cwd.replace('/','-').lstrip('-')
    if cwd.startswith(u):
        slug='-home-'+os.environ.get('USER',os.path.basename(u))+cwd[len(u):].replace('/','-')
    proj_dir=os.path.join(u,'.claude','projects',slug)
else:
    proj_dir=''
print(sid,proj_dir)
" "$sess_file" 2>/dev/null) || return 1
  [ -n "$sid" ] || return 1
  proj_dir="${COMPACT_PROJECT_DIR:-$proj_dir}"
  [ -n "$proj_dir" ] || return 1
  printf '%s %s\n' "$sid" "${proj_dir}/${sid}.jsonl"
}

# probe_pct_from_jsonl <target> [role]: read context % from the session's transcript JSONL
# usage fields (input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# from the last assistant message). Updated every turn, even while the session is
# busy. This is the fallback when the /context probe cannot fire (pane busy).
# Chain: tmux pane PID -> ~/.claude/sessions/<PID>.json -> sessionId ->
# ~/.claude/projects/<project>/<sessionId>.jsonl -> last assistant usage.
probe_pct_from_jsonl() {
  local t="$1" role="${2:-}" sid="" jsonl="" pct win
  read -r sid jsonl < <(pane_session "$t")
  [ -n "$sid" ] && [ -n "$jsonl" ] || return 1
  [ -f "$jsonl" ] || return 1
  win="$(jsonl_window "$role")"
  # The NEWEST of two records wins: the last assistant turn's usage, or the last
  # /context render (Claude Code writes each one into the transcript as a
  # local_command stdout record). An idle pane makes no assistant turns, and every
  # /context probe appends ~23 KB, so after ~11 probes a 256 KB tail held no assistant
  # record at all, and the only current total was the render the probe had just
  # written (seen live: two idle workers blind for hours at "1.6m/500k tokens (324%)").
  # The render's percentage is of the window it prints, so it is restated with
  # rescale_pct like a pane read. The scan stops at a compact_boundary: a render or
  # turn from before the compaction is stale.
  # pipefail is set globally; tac exits 141 (SIGPIPE) when python breaks the pipe
  # after finding its match, which makes the pipeline return non-zero. Read in python
  # directly to avoid the pipe entirely.
  local out kind raw
  out="$(python3 -c "
import json, os, re, sys
f = sys.argv[1]
sz = os.path.getsize(f)
chunk = min(sz, int(sys.argv[3]))
with open(f, 'rb') as fh:
    fh.seek(sz - chunk)
    tail = fh.read().decode('utf-8', errors='replace')
for line in reversed(tail.splitlines()):
    try:
        d = json.loads(line.strip())
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    if d.get('type') == 'assistant' and isinstance(d.get('message'), dict):
        u = d['message'].get('usage') or {}
        total = sum(int(u.get(k) or 0) for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'))
        if total > 0:
            print('usage %d' % (total * 100 // int(sys.argv[2])))
            break
    elif d.get('type') == 'system' and d.get('subtype') == 'compact_boundary':
        break   # anything older describes the context before the compaction
    elif d.get('type') == 'system' and d.get('subtype') == 'local_command':
        c = d.get('content')
        if isinstance(c, str) and '<local-command-stdout>' in c and 'Context Usage' in c:
            print('render')
            print(re.sub(r'\x1b\[[0-9;]*m', '', c))
            break
" "$jsonl" "$win" "$JSONL_TAIL_BYTES" 2>/dev/null)" || return 1
  kind="${out%%$'\n'*}"
  case "$kind" in
    "usage "*) pct="${kind#usage }" ;;
    render)
      raw="$(printf '%s\n' "${out#*$'\n'}" | parse_context_pct)"
      pct="$(rescale_pct "$raw" "$role" "$(printf '%s\n' "${out#*$'\n'}" | context_denominator)")" ;;
    *) return 1 ;;
  esac
  [ -n "$pct" ] && [ "$pct" -ge 0 ] 2>/dev/null && printf '%s' "$pct"
}

# Cooperative: ask a session to compact itself at its own safe checkpoint.
# Plain text, no apostrophes (shell-quoting safety over send-keys).
do_nudge() {
  local t="$1" pct="$2"
  local msg="[compaction-watchdog] Context is at ${pct} percent. When you reach a safe checkpoint (ledger and state written, no in-flight subagent), please run /compact so the run stays in a cheap context. Finish the current step first; there is no rush."
  # No C-u first: a cooperative nudge never wipes a draft; a box holding typed text is refused and logged.
  submit_o "$t" "$msg" 2>/dev/null || log "[$t] nudge not sent: ${TI_REFUSED:-not seen submitted}"
}

# Backstop: force a controlled compaction with focus instructions.
do_compact() {
  local t="$1" rc
  ti_send "$t" "/compact $PRESERVE" clear; rc=$?
  [ -n "${TI_DISCARDED:-}" ] && log "[$t] /compact cleared typed text from the box first: [$TI_DISCARDED]"
  [ "$rc" = 1 ] && log "[$t] /compact not seen submitted: ${TI_REFUSED:-}"
  [ "$rc" = 2 ] || return "$rc"
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "/compact $PRESERVE" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
}

# compact_refused <target>: after a /compact, did Claude Code answer "Not enough
# messages to compact"? An idle session answers within a second; a busy session
# queues the keystroke and answers nothing, which leaves the escalation path below
# intact for a session that is genuinely climbing while busy.
compact_refused() {
  sleep "$PROBE_WAIT"
  tmux_o capture-pane -t "$1" -p 2>/dev/null | strip_ansi | grep -qi 'not enough messages to compact'
}

# Last-resort recovery for the ORCHESTRATOR at the UNRECOVERABLE ceiling
# (compaction failed / hard limit): /clear, then re-brief so it rebuilds from
# disk. This is the manual recovery (forced /clear + rehydrate from state.md)
# automated. ORCHESTRATOR-ONLY: the orchestrator's load-bearing state lives in
# state.md + the ledger, so a clear is safe and the rebrief points it back at
# those rather than summarising from memory. Workers have no such rebrief and are
# escalated to the orchestrator instead (notify_orch_worker_wedged).
orch_rebrief_text() {
  local brief="You are the orchestrator, auto-recovered from a context-limit wedge (compaction could not reduce below the limit, so the watchdog /cleared you; your state is on disk). Re-join the bus: run python3 $repo/bin/bus-inbox.py status orchestrator; if it says reader=none, arm the reader with Bash run_in_background (python3 $repo/bin/bus-inbox.py wait orchestrator 7200), starting the listener first if it is dead (never /is c, never a Monitor on client.py). Then reconstruct the run from ./CLAUDE.md, ./roles/orchestrator.md, and ${TEAM_DIR:-.}/state.md (read the recent tail, including the decision-log). Resume from there; keep context lean (point to files, do not re-read everything, checkpoint+compact at task boundaries). Report status when re-oriented."
  printf '%s' "$brief"
}

# send_rebrief <target> [noblind]: exit 0 when the rebrief was seen submitted (or typed blind into a shell pane with
# no box, unless noblind).
send_rebrief() {
  local t="$1" noblind="${2:-}" brief rc
  brief="$(orch_rebrief_text)"
  ti_send "$t" "$brief" clear; rc=$?
  [ -n "${TI_DISCARDED:-}" ] && log "[$t] rebrief cleared typed text from the box first: [$TI_DISCARDED]"
  [ "$rc" = 2 ] || return "$rc"
  [ -n "$noblind" ] && return 1
  tmux_o send-keys -t "$t" C-u 2>/dev/null
  tmux_o send-keys -t "$t" -l "$brief" 2>/dev/null
  tmux_o send-keys -t "$t" Enter 2>/dev/null
  sleep 1
  tmux_o send-keys -t "$t" Enter 2>/dev/null
}

# A recovery always sends /clear: it runs only at the ceiling, so the context is full again whatever happened before.
# If /clear went in and the rebrief did not, CLEAR_PENDING records the session the /clear started; the main loop retries
# the rebrief (pending_rebrief) while the pane is still in that session with no prompt typed since. A second /clear
# would discard whatever the orchestrator has rebuilt meanwhile, so the retry sends the rebrief only.
CLEAR_PENDING="$HEALTH_DIR/clear-rebrief-pending"
do_clear_rebrief() {
  local t="$1" rc try sid _j
  ti_send "$t" "/clear" clear; rc=$?
  [ -n "${TI_DISCARDED:-}" ] && log "[$t] /clear cleared typed text from the box first: [$TI_DISCARDED]"
  [ "$rc" = 1 ] && { log "clear-rebrief: /clear not seen submitted on $t (${TI_REFUSED:-}); rebrief not typed"; return 1; }
  if [ "$rc" = 2 ]; then
    tmux_o send-keys -t "$t" C-u 2>/dev/null
    tmux_o send-keys -t "$t" -l "/clear" 2>/dev/null
    tmux_o send-keys -t "$t" Enter 2>/dev/null
  fi
  sleep 3
  for try in 1 2 3; do
    send_rebrief "$t" && { rm -f "$CLEAR_PENDING"; return 0; }
    log "clear-rebrief: rebrief not seen submitted on $t (try $try/3: ${TI_REFUSED:-})"
    sleep 3
  done
  sid=""; read -r sid _j < <(pane_session "$t")
  mkdir -p "$HEALTH_DIR" 2>/dev/null
  printf 'sid=%s\nat=%s\n' "${sid:-unknown}" "$(date +%s)" > "$CLEAR_PENDING"
  log "clear-rebrief: orchestrator /cleared but NOT rebriefed (session ${sid:-unknown}); the main loop retries the rebrief only"
  return 1
}

# _transcript_has_prompt <jsonl>: exit 0 when someone typed a prompt in that session (not a slash command, not a hook).
_transcript_has_prompt() {
  [ -f "$1" ] || return 1
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
for line in open(sys.argv[1], errors="replace"):
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "user" or d.get("isMeta"):
        continue
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
            continue
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
    c = (c or "").lstrip()
    if c and not c.startswith(("<command-", "<local-command", "<bash-", "Caveat:")):
        sys.exit(0)
sys.exit(1)
PY
}

# rebrief_tell <text>: tell the orchestrator on the bus (info) that its pane may be cleared with no brief, so that state
# is never silent. Same sink, live-team guard and timeout as blind_bus_notice.
rebrief_tell() {
  local msg="info: compaction-watchdog: $1"
  if [ -n "$BUS_SINK" ]; then
    printf '%s --to orchestrator %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$BUS_SINK" 2>/dev/null || true
    log "clear-rebrief: notice written to the test sink $BUS_SINK"; return 0
  fi
  if [ ! -f "${TEAM_DIR:-.}/state.md" ]; then
    log "clear-rebrief: notice not sent, ${TEAM_DIR:-.} has no state.md (not a live team)"; return 0
  fi
  if BUS_SEND_RETRY_S=0 timeout "$BUS_TIMEOUT" python3 "$BUS_SEND" --name compaction-watchdog --to orchestrator --text "$msg" </dev/null >/dev/null 2>&1; then
    log "clear-rebrief: orchestrator told on the bus"
  else
    log "clear-rebrief: bus-send FAILED, the orchestrator was NOT told"
  fi
}

# _pending_wait <reason>: log a wait; once the marker is over 10 minutes old, tell the orchestrator once.
_pending_wait() {
  log "clear-rebrief: pending rebrief waits ($1)"
  local at; at="$(sed -n 's/^at=//p' "$CLEAR_PENDING" 2>/dev/null)"
  case "$at" in ''|*[!0-9]*) return 0 ;; esac
  if [ $(( $(date +%s) - at )) -gt 600 ] && ! grep -qx 'told=1' "$CLEAR_PENDING" 2>/dev/null; then
    echo 'told=1' >> "$CLEAR_PENDING"
    rebrief_tell "the orchestrator pane was /cleared over 10 minutes ago and the rebrief has still not gone in ($1); it retries each cycle for up to an hour."
  fi
}

# pending_rebrief <target>: retry a rebrief that did not go in after a /clear. The marker is dropped when it is over an
# hour old, when the pane is in another session than the one the /clear started, or when a prompt was typed there
# since: in each case somebody else has dealt with the pane. It fails closed: a marker whose session was never read is
# dropped, a pane whose session cannot be read now waits, and a busy pane or one holding typed text is not touched. It
# never types blind. A drop that leaves the pane unbriefed, and a wait past 10 minutes, are told to the orchestrator.
pending_rebrief() {
  local t="$1" want at sid jsonl etxt txt
  want="$(sed -n 's/^sid=//p' "$CLEAR_PENDING" 2>/dev/null)"; at="$(sed -n 's/^at=//p' "$CLEAR_PENDING" 2>/dev/null)"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  if [ $(( $(date +%s) - at )) -gt 3600 ]; then
    rm -f "$CLEAR_PENDING"; log "clear-rebrief: pending rebrief dropped (over an hour old)"
    rebrief_tell "the orchestrator pane was /cleared over an hour ago and never rebriefed; the retry has stopped. Rebrief it by hand."
    return 0
  fi
  case "$want" in ''|unknown)
    rm -f "$CLEAR_PENDING"; log "clear-rebrief: pending rebrief dropped (the /clear's session was never read)"
    rebrief_tell "the orchestrator pane was /cleared but its session could not be read, so the rebrief is not retried. Rebrief it by hand."
    return 0 ;;
  esac
  sid=""; jsonl=""
  read -r sid jsonl < <(pane_session "$t")
  if [ -z "$sid" ]; then _pending_wait "pane session unreadable"; return 0; fi
  if [ "$sid" != "$want" ]; then
    rm -f "$CLEAR_PENDING"; log "clear-rebrief: pending rebrief dropped (pane now in session $sid, the /clear started $want)"; return 0
  fi
  if [ -n "$jsonl" ] && _transcript_has_prompt "$jsonl"; then
    rm -f "$CLEAR_PENDING"; log "clear-rebrief: pending rebrief dropped (a prompt was typed in session $sid since the /clear)"; return 0
  fi
  etxt="$(tmux_o capture-pane -e -t "$t" -p 2>/dev/null)"
  txt="$(printf '%s' "$etxt" | strip_ansi)"
  if [ -z "$txt" ] || is_busy "$txt"; then _pending_wait "pane busy or empty"; return 0; fi
  case "$(input_class "$txt" "$etxt")" in
    real) _pending_wait "real unsubmitted text on the input line"; return 0 ;;
  esac
  if send_rebrief "$t" noblind; then
    rm -f "$CLEAR_PENDING"; log "clear-rebrief: pending rebrief sent (session ${sid:-unknown})"
  else
    _pending_wait "rebrief not seen submitted"
  fi
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
  local msg="[compaction-watchdog] Worker '${role}' is at an unrecoverable context ceiling (${cstate}); compaction cannot recover it. You own retire+respawn: please retire and respawn '${role}'. Its task state is on disk / in its PR; rebrief it fresh." rc
  ti_send "$ot" "$msg" clear; rc=$?
  [ -n "${TI_DISCARDED:-}" ] && log "[$role] wedge-notice cleared typed text from the orchestrator box first: [$TI_DISCARDED]"
  [ "$rc" = 1 ] && log "[$role] wedge-notice not seen submitted: ${TI_REFUSED:-}"
  [ "$rc" = 2 ] || return 0
  tmux_o send-keys -t "$ot" -l "$msg" 2>/dev/null
  tmux_o send-keys -t "$ot" Enter 2>/dev/null
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
    echo "      capture-pane (no alt-screen scrollback); a live worker went blind this way."
    echo "Action: the role should /compact at a safe checkpoint; if (a), update parse_context_pct."
    echo "Attach: TEAM_RUN_ID=${TEAM_RUN_ID:-?} bin/attach.sh"
  } > "$m.tmp.$$" 2>/dev/null \
    && mv -f "$m.tmp.$$" "$m" 2>/dev/null \
    || rm -f "$m.tmp.$$" 2>/dev/null || true
  # Probe-blind is an instrument state, not an actionable event — nobody can act on
  # it from a phone notification. Reclassified from action/page to a log line:
  # paging for nothing anyone could act on erodes trust in the alert channel. The
  # watchdog still drives /compact (safe direction) and notifies the orchestrator
  # pane (for workers).
  log "[$role] PROBE-BLIND-ALARM: context probe blind ${n} cycles; early compaction OFF (CC format change OR large-context viewport overflow). See $m"
  # DRIVE /compact on the role's own pane. We cannot read its %, but compacting is
  # the safe direction when blind.
  do_compact "$t"
  # For a WORKER, also tell the orchestrator (it can prompt a compact or retire+respawn).
  if [ "$is_orch" != "1" ]; then
    local ot oet otxt; ot="$(orch_target)" || return 0
    oet="$(tmux_o capture-pane -e -t "$ot" -p 2>/dev/null)"; otxt="$(printf '%s' "$oet" | strip_ansi)"
    if [ -z "$otxt" ] || is_busy "$otxt"; then return 0; fi
    case "$(input_class "$otxt" "$oet")" in real) return 0 ;; esac
    local msg="[compaction-watchdog] Worker '${role}' is probe-blind (${n} cycles): I cannot read its context % to compact it early (likely a large context overflowing /context in fullscreen TUI). I have driven a /compact on it; if it wedges, retire+respawn." rc
    ti_send "$ot" "$msg" clear; rc=$?
    [ -n "${TI_DISCARDED:-}" ] && log "[$role] probe-blind notice cleared typed text from the orchestrator box first: [$TI_DISCARDED]"
    [ "$rc" = 1 ] && log "[$role] probe-blind notice not seen submitted: ${TI_REFUSED:-}"
    [ "$rc" = 2 ] || return 0
    tmux_o send-keys -t "$ot" -l "$msg" 2>/dev/null
    tmux_o send-keys -t "$ot" Enter 2>/dev/null
  fi
}

# blind_footer_compact <role> <target> <pane-text> <now>: the probe is blind, but the
# pane's own status footer says how close auto-compact is. At or past the force band
# ("N% until auto-compact" with N <= 100 - FORCE_R) drive a /compact, debounced like
# any forced one. Called only on an idle pane (a busy one returns before the probe).
blind_footer_compact() {
  local role="$1" t="$2" txt="$3" nowt="$4" left
  left="$(printf '%s' "$txt" | until_autocompact_pct)"
  [ -n "$left" ] || return 0
  [ "$left" -le $(( 100 - FORCE_R )) ] || return 0
  if [ $(( nowt - ${last_compact[$role]:-0} )) -lt "$DEBOUNCE" ]; then
    log "[$role] blind-footer-suppressed: footer ${left}% until auto-compact (within ${DEBOUNCE}s force debounce)"
    return 0
  fi
  log "[$role] BLIND-FOOTER-COMPACT: probe blind, footer shows ${left}% until auto-compact; forcing /compact"
  do_compact "$t"; last_compact[$role]=$nowt
}

# blind_bus_notice <role> <n> <is_orch> <pane-text>: tell the orchestrator on the bus
# that a worker is still blind, at the PROBE_FAIL_ALARM-th consecutive failure and
# every BLIND_BUS_EVERY after it. The outcome is logged both ways: an unlogged failure
# looks the same as delivery.
blind_bus_notice() {
  local role="$1" n="$2" is_orch="$3" txt="$4" left msg
  [ "$is_orch" = "1" ] && return 0
  [ "$BLIND_BUS_EVERY" -gt 0 ] 2>/dev/null || return 0
  [ "$n" -ge "$PROBE_FAIL_ALARM" ] || return 0
  [ $(( (n - PROBE_FAIL_ALARM) % BLIND_BUS_EVERY )) -eq 0 ] || return 0
  left="$(printf '%s' "$txt" | until_autocompact_pct)"
  msg="status: compaction-watchdog cannot read ${role} context for ${n} cycles (since $(date -u -d "@${blind_since[$role]:-$(date +%s)}" +%H:%MZ)); pane footer: ${left:+${left}% until auto-compact}${left:-none}. Last compact sent $(( ${last_compact[$role]:-0} > 0 ? ($(date +%s) - ${last_compact[$role]:-0}) / 60 : -1 ))m ago (-1 = never this run). Check the pane; compact or retire+respawn."
  if [ -n "$BUS_SINK" ]; then
    printf '%s --to orchestrator %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$BUS_SINK" 2>/dev/null || true
    log "[$role] BLIND-BUS: written to the test sink $BUS_SINK (${n} cycles)"
    return 0
  fi
  if [ ! -f "${TEAM_DIR:-.}/state.md" ]; then
    log "[$role] BLIND-BUS: not sent, ${TEAM_DIR:-.} has no state.md (not a live team; a test sets COMPACT_BUS_SINK) (${n} cycles)"
    return 0
  fi
  if BUS_SEND_RETRY_S=0 timeout "$BUS_TIMEOUT" python3 "$BUS_SEND" --name compaction-watchdog --to orchestrator --text "$msg" </dev/null >/dev/null 2>&1; then
    log "[$role] BLIND-BUS: orchestrator told on the bus (${n} cycles)"
  else
    log "[$role] BLIND-BUS: bus-send FAILED, the orchestrator was NOT told (${n} cycles)"
  fi
}

# Per-role state (associative arrays keyed by role name).
declare -A last_fp fp_since last_compact last_nudge last_recover ceiling_seen probe_fail probe_blind_alarmed force_count force_stuck_alarmed blind_since

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
          force_count[$role]=$(( ${force_count[$role]:-0} + 1 ))
          log "[$role] CEILING-WARN: near-full warning on pane (busy-agnostic); forcing /compact (attempt ${force_count[$role]} this episode)"
          do_compact "$t"; last_compact[$role]=$nowt
          # Claude Code's own verdict beats layout inference. "Not enough messages to
          # compact" means the session is at its FLOOR: the near-full text on the pane
          # is stale (a render or chrome that has not scrolled off), not a ceiling.
          # End the episode instead of counting the refusal towards CEILING-STUCK.
          if compact_refused "$t"; then
            log "[$role] CEILING-STALE: /compact refused (not enough messages to compact); near-full text is stale, episode reset (forced this episode: ${force_count[$role]})"
            force_count[$role]=0; force_stuck_alarmed[$role]=0
            rm -f "$(role_marker "$role")" 2>/dev/null || true
          # A forced /compact that does not clear the warning is not progress. Keep
          # forcing (it eventually lands when the pane goes idle), but after
          # FORCE_ESCALATE attempts say so, once, to the operator and the status hook:
          # a coordinator that cannot compact is a coordinator that is not answering.
          elif [ "${force_count[$role]}" -ge "$FORCE_ESCALATE" ] && [ "${force_stuck_alarmed[$role]:-0}" != 1 ]; then
            force_stuck_alarmed[$role]=1
            log "[$role] CEILING-STUCK: ${force_count[$role]} forced compactions and the pane is still near-full; escalating (ntfy + status hook)"
            notify "🔴 [compaction-watchdog/${TEAM_RUN_ID:-legacy}] '${role}' still near-full after ${force_count[$role]} forced /compact attempts (~$(( force_count[$role] * DEBOUNCE / 60 ))m); it may not be answering. Marker: $(role_marker "$role")"
            status_hook compact-stuck "$role" "context near-full and ${force_count[$role]} forced compactions did not clear it; the operator has been alerted"
          fi
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
  if [ -f "$m" ]; then
    rm -f "$m" 2>/dev/null || true; ceiling_seen[$role]=0
    log "[$role] CEILING-CLEARED: pane healthy again (forced compactions this episode: ${force_count[$role]:-0})"
    [ "${force_stuck_alarmed[$role]:-0}" = 1 ] && status_hook recovered "$role" "context compacted after ${force_count[$role]:-0} forced attempts; answering again"
    force_count[$role]=0; force_stuck_alarmed[$role]=0
  fi

  # Ceiling-guard-only target (default-model worker): no /context probe.
  [ "$probe" = 1 ] || return

  local _busy=0
  is_busy "$txt" && _busy=1

  if [ "$fp" != "${last_fp[$role]:-}" ]; then
    last_fp[$role]="$fp"; fp_since[$role]=$nowt
    if [ "$_busy" = 1 ]; then
      # Pane changed AND busy: the /context probe can never fire while the session
      # is working (the pane never stabilises for IDLE_SEC). Fall back to reading
      # the context % from the transcript JSONL, which is updated every turn.
      pct="$(probe_pct_from_jsonl "$t" "$role" 2>/dev/null)" || pct=""
      if [ -n "$pct" ]; then
        log "[$role] jsonl-probe: ${pct}% (busy pane, read from transcript)"
      else
        log "[$role] skip: busy + jsonl fallback failed"
        return
      fi
    else
      return
    fi
  fi
  idle=$(( nowt - ${fp_since[$role]:-$nowt} ))
  [ "$idle" -lt "$IDLE_SEC" ] && return
  if [ "$_busy" = 1 ]; then
    # Pane is busy: the /context probe cannot fire. Fall back to reading the
    # context % from the session's transcript JSONL, which is updated every turn
    # even while the session is working.
    pct="$(probe_pct_from_jsonl "$t" "$role" 2>/dev/null)" || pct=""
    if [ -n "$pct" ]; then
      log "[$role] jsonl-probe: ${pct}% (busy pane, read from transcript)"
    else
      log "[$role] skip: busy + jsonl fallback failed"
      return
    fi
  else
    case "$(input_class "$txt" "$etxt")" in
      real) log "[$role] skip: real unsubmitted text on input line"; return ;;
    esac

    # Transcript-first probe (2026-09-10). Read the context % from the session's
    # transcript JSONL BEFORE falling back to /context. A /context probe injects a
    # ~17.9k-character user message (+8k tokens) into the probed session every time
    # it fires; on an idle pane with the backoff disabled near the nudge that is
    # ~32k tokens an hour of monitoring overhead and drives compactions with no
    # operator traffic. The transcript read is a file read, no tmux injection.
    # /context stays as the fallback when the transcript cannot be read.
    pct="$(probe_pct_from_jsonl "$t" "$role" 2>/dev/null)" || pct=""
    if [ -n "$pct" ]; then
      log "[$role] jsonl-probe: ${pct}% (idle pane, read from transcript)"
    else
      pct="$(probe_pct "$t" "$role")"
      last_fp[$role]=""   # /context changed the pane; force a fresh baseline next pass
      if [ -n "$pct" ]; then
        log "[$role] pane-probe: ${pct}% (idle pane, /context fallback)"
      else
        # The pane could not show the total (an over-limit render is taller than an
        # 80x24 pane), but the render the probe just ran is now in the transcript.
        pct="$(probe_pct_from_jsonl "$t" "$role" 2>/dev/null)" || pct=""
        [ -n "$pct" ] && log "[$role] jsonl-probe: ${pct}% (pane unreadable; read the /context render back from the transcript)"
      fi
    fi
  fi
  if [ -z "$pct" ]; then
    probe_fail[$role]=$(( ${probe_fail[$role]:-0} + 1 ))
    [ "${probe_fail[$role]}" -eq 1 ] && blind_since[$role]=$nowt
    log "[$role] probe: could not read context % (${probe_fail[$role]} consecutive)"
    if [ "${probe_fail[$role]}" -ge "$PROBE_FAIL_ALARM" ] && [ "${probe_blind_alarmed[$role]:-0}" = 0 ]; then
      log "[$role] PROBE-BLIND: ${probe_fail[$role]} consecutive parse failures; alarming + marker (CC /context format may have changed)"
      probe_blind_alarm "$role" "$t" "${probe_fail[$role]}" "$is_orch"
      probe_blind_alarmed[$role]=1
      last_compact[$role]=$nowt   # the alarm drove a /compact
    fi
    blind_footer_compact "$role" "$t" "$txt" "$nowt"
    blind_bus_notice "$role" "${probe_fail[$role]}" "$is_orch" "$txt"
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
    # /context failed. Before alarming, try the transcript: a busy pane that
    # is_busy does not catch (tool output streaming, mid-render) makes /context
    # unreadable while the jsonl transcript still reads. A successful jsonl read
    # means the instrument is fine and the pane was uncooperative at startup.
    pct="$(probe_pct_from_jsonl "$t" orchestrator 2>/dev/null)" || pct=""
    if [ -n "$pct" ]; then
      log "canary: /context probe failed but jsonl-probe read ${pct}%; instrument healthy, pane busy at startup"
      return
    fi
    log "CANARY-FAIL: probe parsed empty on a live pane at startup and the jsonl fallback also failed. CC /context format may have changed (parser blind). Raising alarm."
    probe_blind_alarm "orchestrator" "$t" 0 1
  else
    log "canary: probe healthy at startup (read ${pct}%)"
  fi
}

# Sourcing hook for the unit tests: with COMPACT_TEST_SOURCE=1 the file defines its
# functions and stops here, so a test can call them directly instead of driving the
# whole daemon through a fake tmux. It stops BEFORE the start-line, the canary and
# the main loop, so sourcing injects no keystroke into any pane.
if [ -n "${COMPACT_TEST_SOURCE:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

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
      _ac="$(autocompact_window "$(role_model "$r")")"
      start_targets+="${r}(${NUDGE_R}/${FORCE_R}${_ac:+ autocompact ${_ac}}$([ "$orchf" = 1 ] && echo ,orch)) "
    else
      start_targets+="${r}(ceiling-only) "
    fi
  done < "$_st_tmp"
fi
rm -f "$_st_tmp" 2>/dev/null
log "start: multi-target watching: ${start_targets:-<none yet>}| idle=${IDLE_SEC}s interval=${INTERVAL}s nudge_debounce=${NUDGE_DEBOUNCE}s force_debounce=${DEBOUNCE}s ceiling-guard=on autorecover=${AUTORECOVER}(orch-only) probe-blind-alarm=${PROBE_FAIL_ALARM} sock=${SOCK} session=${SESSION:-auto}"
canary

while :; do
  self_reload_check "$0" ${_SR_ORIG_ARGS[@]+"${_SR_ORIG_ARGS[@]}"}
  if ! enumerate_targets > "${TEAM_DIR:-.}/.compaction-targets.$$" 2>/dev/null || [ ! -s "${TEAM_DIR:-.}/.compaction-targets.$$" ]; then
    log "no targets on socket $SOCK (no orch session?)"; rm -f "${TEAM_DIR:-.}/.compaction-targets.$$" 2>/dev/null
    sleep "$INTERVAL"; continue
  fi
  while read -r role target orchflag probeflag; do
    [ -n "$role" ] || continue
    if [ "$orchflag" = 1 ] && [ -f "$CLEAR_PENDING" ]; then
      pending_rebrief "$target"
      continue
    fi
    process_target "$role" "$target" "$orchflag" "$probeflag"
  done < "${TEAM_DIR:-.}/.compaction-targets.$$"
  rm -f "${TEAM_DIR:-.}/.compaction-targets.$$" 2>/dev/null
  sleep "$INTERVAL"
done

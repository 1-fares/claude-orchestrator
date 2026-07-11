# team-env.sh: sourced (not executed) by the team scripts. Gives each clone its
# own isolated bus and tmux session, isolated from your default tmux server.
# Supports two modes:
#   - **Legacy / single-team mode** (no TEAM_RUN_ID in env): this clone has one
#     team at a time, on a per-clone bus port and tmux session, with state in
#     $TEAM_REPO/.team. This is today's behavior, preserved for backward compat.
#   - **Per-run mode** (TEAM_RUN_ID set, by bin/run.sh per invocation, inherited
#     by spawned children): the team gets its own bus port, tmux session, and
#     state dir derived from (clone-path + run-id), so PARALLEL teams in the
#     same clone do not collide on names, ports, or state.
#
# Exports:
#   TEAM_REPO       absolute path of this clone
#   TEAM_RUN_ID     (optional) per-run identifier; when set, port/session/dir
#                   are derived per-run. Empty/unset = legacy mode.
#   TEAM_SESSION    tmux session name for this team (orch-<hash>)
#   TEAM_PORT       /is bus port for this team (9500-9899, derived)
#   TEAM_DIR        per-team state dir ($TEAM_REPO/.team or .team-<run-id>)
#   TEAM_TMUX       dedicated tmux socket name for the team
#   TEAM_TMUX_BIN   path to the real tmux binary
#   TEAM_TMUX_CONF  the team's tmux config file
#   INTER_SESSION_PORT  set to TEAM_PORT so spawned claude sessions join this bus
# A pre-set INTER_SESSION_PORT is honored (manual override).
#
# Why a dedicated tmux socket + own config: tmux-resurrect/continuum on the
# DEFAULT server auto-save and auto-restore sessions; on the default socket they
# resurrect the team's windows as stale shells after teardown. The team runs on
# its own socket (-L) loaded with ONLY team.tmux.conf (never ~/.tmux.conf), so no
# plugins, no auto-restore, but your prefix/mouse are carried over.

TEAM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_team_hash="$(printf '%s' "$TEAM_REPO" | cksum | cut -d' ' -f1)"

# Capture any pre-set TEAM_DIR BEFORE we derive the canonical one, so we can refuse
# to SILENTLY override it. Failure mode this guards: a test sets TEAM_DIR="$(mktemp -d)"
# and `trap rm -rf "$TEAM_DIR"`, then sources this file, which silently re-points
# TEAM_DIR at the live run dir; the trap then wipes the live run. We must never
# silently move a caller's TEAM_DIR onto a different (especially live) path.
_preset_team_dir="${TEAM_DIR:-}"

# Test-isolation tripwire (2026-07-11 incident). A test sourced from bin/tests/
# that INHERITS a live run's TEAM_RUN_ID derives the live run's dir, session,
# and socket, and its cleanup (rm -rf "$TEAM_DIR", kill-session) then destroys
# the live run — with an internally-consistent env the TEAM_DIR guard below
# cannot see anything wrong. So: when any caller in the source chain is under
# bin/tests/, require the throwaway names from bin/tests/lib/isolate.sh.
_te_caller_is_test=0
for _te_src in "${BASH_SOURCE[@]:-}"; do
  case "$_te_src" in */bin/tests/*|bin/tests/*|tests/*) _te_caller_is_test=1;; esac
done
if [ "$_te_caller_is_test" = 1 ]; then
  case "${TEAM_RUN_ID:-}" in
    test*|wdtest*|potest*) : ;;  # isolate.sh names + grandfathered per-test prefixes
    *) echo "team-env: caller is under bin/tests/ but TEAM_RUN_ID='${TEAM_RUN_ID:-<unset>}' is not a test id." >&2
       echo "  Source bin/tests/lib/isolate.sh FIRST (it exports throwaway TEAM_RUN_ID/TEAM_TMUX)." >&2
       echo "  Refusing: an inherited live run id here is how a test's cleanup wiped a live run." >&2
       # exit, not return: on `return` the sourcing test would carry on with
       # partially-derived names, which is exactly the state being prevented.
       exit 97 ;;
  esac
fi
unset _te_caller_is_test _te_src

if [ -n "${TEAM_RUN_ID:-}" ]; then
  # Per-run: derive port + session + state dir from (clone-path + run-id) so
  # parallel teams in this clone do not collide.
  _run_hash="$(printf '%s\0%s' "$TEAM_REPO" "$TEAM_RUN_ID" | cksum | cut -d' ' -f1)"
  TEAM_SESSION="orch-${_run_hash: -5}"
  _port_seed=$((9500 + _run_hash % 400))
  _canonical_team_dir="$TEAM_REPO/.team-$TEAM_RUN_ID"
  unset _run_hash
else
  # Legacy / single-team: today's per-clone derivation, state in .team/.
  TEAM_SESSION="orch-${_team_hash: -5}"
  _port_seed=$((9500 + _team_hash % 400))
  _canonical_team_dir="$TEAM_REPO/.team"
fi

# Resolve TEAM_DIR, refusing a SILENT override of a pre-set value (structural guard).
# No normal team script pre-sets TEAM_DIR -- they let this file derive it -- so the
# only callers that hit a conflict are tests/misuse, which must fail loud, not have
# their TEAM_DIR quietly moved onto the live run dir (see bin/lib/team-dir-guard.sh).
if [ -z "$_preset_team_dir" ] || [ "$_preset_team_dir" = "$_canonical_team_dir" ]; then
  # Normal path: nothing pre-set, or pre-set already equals the canonical dir (an
  # idempotent re-source, e.g. a role running a gate with TEAM_DIR already exported).
  TEAM_DIR="$_canonical_team_dir"
elif [ "${TEAM_DIR_ALLOW_OVERRIDE:-0}" = "1" ]; then
  # Explicit, opt-in isolation (a test that genuinely wants its own TEAM_DIR while
  # still using this file's helpers). Honor the pre-set value; never the live run.
  echo "team-env: honoring explicit TEAM_DIR='$_preset_team_dir' (TEAM_DIR_ALLOW_OVERRIDE=1; canonical would be '$_canonical_team_dir')" >&2
  TEAM_DIR="$_preset_team_dir"
else
  # Conflict: a pre-set TEAM_DIR that this run would otherwise SILENTLY replace.
  # Refuse loudly and leave TEAM_DIR as the caller set it (NEVER move it onto the
  # canonical/live run dir), so a `trap rm -rf "$TEAM_DIR"` can never hit the live run.
  echo "team-env: REFUSING to silently override a pre-set TEAM_DIR." >&2
  echo "  pre-set:   $_preset_team_dir" >&2
  echo "  canonical: $_canonical_team_dir  (derived from TEAM_RUN_ID='${TEAM_RUN_ID:-}')" >&2
  echo "  This guards against a test/script wiping a LIVE run dir." >&2
  echo "  Fix one of: unset TEAM_DIR before sourcing (use the canonical run dir); or" >&2
  echo "  unset TEAM_RUN_ID (use your explicit dir); or set TEAM_DIR_ALLOW_OVERRIDE=1" >&2
  echo "  to deliberately keep your explicit TEAM_DIR. TEAM_DIR left as-is; not proceeding." >&2
  TEAM_DIR="$_preset_team_dir"
  # Clear the half-derived vars so a caller that ignores this non-zero return is left
  # with NO usable team identity (rather than TEAM_SESSION pointing at the live team
  # while TEAM_DIR is the caller's scratch). TEAM_DIR stays the caller's value.
  unset _preset_team_dir _canonical_team_dir _team_hash _port_seed TEAM_SESSION TEAM_PORT
  return 1 2>/dev/null || exit 1
fi
unset _preset_team_dir _canonical_team_dir
: "${INTER_SESSION_PORT:=$_port_seed}"
TEAM_PORT="$INTER_SESSION_PORT"
unset _port_seed
TEAM_TMUX="${TEAM_TMUX:-orchestrator}"
# Resolve the real tmux binary now, before the wrapper function shadows the name,
# so callers can exec it directly (exec cannot run the `command` builtin).
TEAM_TMUX_BIN="$(command -v tmux 2>/dev/null || echo tmux)"
TEAM_TMUX_CONF="$TEAM_REPO/team.tmux.conf"
unset _team_hash

# Generate the team's tmux config once, importing your prefix/mouse from
# ~/.tmux.conf but none of the plugins. Edit it freely afterwards; it is
# per-clone and gitignored.
if [ ! -f "$TEAM_TMUX_CONF" ]; then
  # `|| true`: with `set -euo pipefail`, a missing ~/.tmux.conf (or no prefix line)
  # makes this grep pipeline fail and would abort the whole launch. Default to C-b.
  _pfx="$(grep -hoE '^[[:space:]]*set(-option)?[[:space:]]+(-g[[:space:]]+)?prefix[[:space:]]+[CMS]-[a-zA-Z]' "$HOME/.tmux.conf" 2>/dev/null | grep -oE '[CMS]-[a-zA-Z]$' | head -1)" || true
  _pfx="${_pfx:-C-b}"
  {
    echo "# Team tmux config. The team runs on its own tmux socket loaded with"
    echo "# ONLY this file (never ~/.tmux.conf), so tmux plugins like"
    echo "# resurrect/continuum never touch the team and cannot auto-restore stale"
    echo "# sessions. Imported your prefix/mouse; edit freely (per-clone, gitignored)."
    echo "set -g prefix $_pfx"
    [ "$_pfx" != "C-b" ] && echo "unbind C-b"
    echo "bind $_pfx send-prefix"
    echo "set -g mouse on"
  } > "$TEAM_TMUX_CONF"
  unset _pfx
fi

export TEAM_REPO TEAM_SESSION TEAM_PORT INTER_SESSION_PORT TEAM_TMUX TEAM_TMUX_BIN TEAM_TMUX_CONF TEAM_DIR
[ -n "${TEAM_RUN_ID:-}" ] && export TEAM_RUN_ID

# Route every tmux call in the sourcing script through the team's own socket and
# config. The -f applies when this call starts the server; it is ignored once the
# server is running.
tmux() { "$TEAM_TMUX_BIN" -L "$TEAM_TMUX" -f "$TEAM_TMUX_CONF" "$@"; }

# tmux_submit <target> <message>: type a literal message into a role's Claude Code
# pane and submit it. A message long enough to collapse into a [Pasted text] block
# needs TWO Enters: the first only inserts a newline inside the block, the second
# submits. A single Enter therefore leaves long broadcasts, approvals, and watchdog
# nudges sitting unsent in the input. The trailing Enter on an already-submitted
# (now empty) prompt is a harmless no-op, so this is also correct for short
# messages. Routes through the team socket via the tmux() wrapper above.
tmux_submit() {
  local target="$1" msg="$2"
  tmux send-keys -t "$target" -l "$msg" 2>/dev/null || return 1
  tmux send-keys -t "$target" Enter 2>/dev/null || true
  sleep 0.4
  tmux send-keys -t "$target" Enter 2>/dev/null || true
}

# Pin Claude Code: native installs auto-update in the BACKGROUND of any running
# session and silently repoint ~/.local/bin/claude to the newest version -- that
# is how a mid-run upgrade (to 2.1.170) once changed the /context format and
# broke the compaction watchdog's probe. Upgrades must be deliberate.
# DISABLE_AUTOUPDATER stops the background updater but leaves
# `claude install <version>` working for an intentional upgrade. This is the
# team-process belt; the authoritative host-wide lever is the same key in
# ~/.claude/settings.json env plus minimumVersion. Deliberate-upgrade procedure
# (canary-green-first gate): docs/cc-version-pin.md.
export DISABLE_AUTOUPDATER="${DISABLE_AUTOUPDATER:-1}"

# Per-role model overrides that must survive respawns and restarts belong HERE,
# not in the launching shell: every spawn path (launch, add-role, watchdog
# re-ensure) sources this file, so an override set here outlives the session
# that first exported it. Use it to pin judgment-dense roles to the top tier
# (diagnosis-heavy implementers, schema/domain experts) while mechanical roles
# stay on the default tier; see docs/model-policy.md for the tier rationale.
# Example:
#   export TEAM_MODEL_IMPLEMENTER1="${TEAM_MODEL_IMPLEMENTER1:-fable}"

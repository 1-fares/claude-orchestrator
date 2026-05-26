#!/usr/bin/env bash
# role-activity.sh: classify a role pane's runtime activity from its tmux pane.
# Output: one of `working`, `delegating:<N>`, `delegating`, `idle`. The
# dashboard server (bin/dashboard/server/server.py, u24-server-half) calls this
# per role per tick to fill the per-role `activity` field in /state.json.
#
# Distinguishes three behaviours the existing api-watchdog conflates:
#   1. Role doing work itself                    -> `working`
#   2. Role waiting on Agent-tool subagents       -> `delegating[:N]`
#   3. Role at the `❯ Try` prompt, doing nothing  -> `idle`
#
# Patterns (in priority order, more-specific first):
#   * Subagent indicator. Claude Code's TUI shows `N background tasks` (or the
#     singular `1 background task`) once any subagent is in flight; that line
#     is the strongest signal. A `Task(` invocation in the recent pane scroll
#     is a weaker signal (the operator may scroll history past it) and only
#     promotes to `delegating` when no spinner is also present.
#   * Busy spinner. `Working…`, `Cooked for`, `Brewed for`, `Thinking`, or the
#     `↓ N tokens` token counter — any of these means the role is actively
#     processing.
#   * Else: the pane shows the `❯ ` (or `❯ Try`) input prompt with no spinner
#     and no subagent line above it. That is `idle`.
#
# Exit 0 on classification (any of the four outputs). Exit non-zero on tmux
# capture failure; the caller (server.py) falls back to the api-watchdog state.
#
# Usage: bin/role-activity.sh <role-name>
#   <role-name> matches the bus name (^[a-z0-9][a-z0-9-]{0,39}$) and looks up
#   the role's tmux window via $TEAM_DIR/active. Env override below.
#
# Env:
#   ROLE_ACTIVITY_CAPTURE   override path to a pre-captured pane buffer (used
#                           by the smoke harness so it can feed in fixtures
#                           without spinning up a real tmux pane).
#   TEAM_DIR, TEAM_SESSION, TEAM_TMUX, TEAM_TMUX_BIN  resolved via team-env.sh
#                                                     when not pre-exported.

set -uo pipefail

role="${1:-}"
[ -n "$role" ] || { echo "usage: $0 <role-name>" >&2; exit 2; }
case "$role" in
  [a-z0-9]*) : ;;
  *) echo "invalid role name: '$role'" >&2; exit 2 ;;
esac
printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$' \
  || { echo "invalid role name: '$role'" >&2; exit 2; }

# Capture the pane: either from the env override (fixture) or via tmux.
if [ -n "${ROLE_ACTIVITY_CAPTURE:-}" ]; then
  [ -r "$ROLE_ACTIVITY_CAPTURE" ] || { echo "capture not readable: $ROLE_ACTIVITY_CAPTURE" >&2; exit 3; }
  pane="$(cat "$ROLE_ACTIVITY_CAPTURE")"
else
  # Resolve team-env (idempotent: a no-op when the vars are already exported).
  if [ -z "${TEAM_DIR:-}" ] || [ -z "${TEAM_SESSION:-}" ] || [ -z "${TEAM_TMUX:-}" ]; then
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=bin/team-env.sh
    . "$repo/bin/team-env.sh"
  fi
  active="$TEAM_DIR/active"
  [ -f "$active" ] || { echo "active roster not found: $active" >&2; exit 3; }
  # active rows are tab-separated: pid<TAB>window-id<TAB>role-name
  wid="$(awk -F'\t' -v r="$role" '$3 == r {print $2; exit}' "$active")"
  [ -n "$wid" ] || { echo "role '$role' not in active roster" >&2; exit 3; }
  tmux_bin="${TEAM_TMUX_BIN:-tmux}"
  pane="$("$tmux_bin" -L "$TEAM_TMUX" capture-pane -p -t "$TEAM_SESSION:$wid" 2>/dev/null)" || {
    echo "tmux capture-pane failed for $role ($TEAM_SESSION:$wid)" >&2
    exit 3
  }
fi

# Subagent count. Match `N background tasks` (plural >=2), `1 background task`,
# or the bare `Task(` invocation in the recent scroll. The plural-with-count
# wins because it carries N; the singular falls back to N=1; the bare `Task(`
# emits `delegating` with no count.
n_bg="$(printf '%s\n' "$pane" \
        | grep -oE '[0-9]+ background tasks?' \
        | tail -1 \
        | awk '{print $1}')"
if [ -n "$n_bg" ] && [ "$n_bg" -gt 0 ]; then
  echo "delegating:$n_bg"
  exit 0
fi

if printf '%s\n' "$pane" | grep -Eq '(^|[^a-zA-Z])Task\('; then
  # Bare Task( invocation visible in scroll; no parseable count.
  # Only promote to delegating if no active spinner is also present, since a
  # spinner means the role is processing the result, not waiting on a subagent.
  if ! printf '%s\n' "$pane" \
       | grep -Eq 'Working…|Cooked for|Brewed for|Thinking|↓ *[0-9]+ *tokens'; then
    echo "delegating"
    exit 0
  fi
fi

# Busy spinner: any of Claude Code's processing indicators.
if printf '%s\n' "$pane" \
     | grep -Eq 'Working…|Cooked for|Brewed for|Thinking|↓ *[0-9]+ *tokens'; then
  echo "working"
  exit 0
fi

# Else: idle. Soft check that the pane shows an input prompt (`❯ ` or `❯ Try`).
# If it doesn't, we still classify as idle (the pane may show an empty REPL
# or a transient state) — the caller's chain decides whether to honour or
# override via api-watchdog state.
echo "idle"
exit 0

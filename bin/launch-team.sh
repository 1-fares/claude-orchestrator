#!/usr/bin/env bash
# launch-team.sh: spawn a team of Claude Code role-sessions in tmux, each
# joined to the inter-session (/is) bus. Driven by the orchestrator through its
# Bash tool, or run by hand.
#
# Usage:
#   bin/launch-team.sh [--workdir DIR] <goal-file> <role> [<role> ...]
#
# Examples:
#   # greenfield: build inside this clone (working tree = this repo)
#   bin/launch-team.sh goals/checkout-bug.md architect implementer1 tester1
#
#   # existing codebase: drive a project that lives elsewhere
#   bin/launch-team.sh --workdir ~/projects/some-app \
#       goals/repo-bugfix.md implementer1 tester1
#
# --workdir DIR   Directory the role sessions run in (default: this repo). Point
#                 it at the target codebase so roles edit the right tree and pick
#                 up that project's own CLAUDE.md. The orchestrator's CLAUDE.md,
#                 role file, and goal are read by absolute path regardless.
#
# A role name maps to a prompt file by stripping trailing digits:
#   implementer1, implementer2 -> roles/implementer.md
# The bare role name is the bus name, so the orchestrator addresses it directly:
#   /is s implementer1 ...
#
# Concurrent teams: to run more than one team at once, give each team its own bus
# by exporting INTER_SESSION_PORT before launching (and in the orchestrator
# session too). This launcher propagates INTER_SESSION_PORT and
# INTER_SESSION_IDLE_MINUTES into the spawned sessions. See README "Future work".
#
# Sessions start with --dangerously-skip-permissions so they run unattended.
# Only use this in a trusted local environment. Sessions are interactive (not
# `claude -p`): a print-mode session exits after one response and would kill a
# long-lived worker, so we keep them interactive and let the /is monitor hold
# them open between messages.
#
# Requires: tmux, and `claude` on PATH.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/team-env.sh
. "$repo/bin/team-env.sh"   # sets TEAM_SESSION, TEAM_PORT, INTER_SESSION_PORT
session="$TEAM_SESSION"
flags="--dangerously-skip-permissions"

usage() { echo "usage: $0 [--workdir DIR] <goal-file> <role> [<role> ...]" >&2; exit 1; }

# --- parse optional flags -------------------------------------------------
workdir="$repo"
while [ "${1:-}" = "--workdir" ] || [ "${1:-}" = "-w" ]; do
  [ "$#" -ge 2 ] || usage
  workdir="$2"; shift 2
done

[ "$#" -ge 2 ] || usage
goal="$1"; shift

if ! workdir_abs="$(cd "$workdir" 2>/dev/null && pwd)"; then
  echo "workdir is not a directory: $workdir" >&2; exit 1
fi

# Resolve the goal to an absolute path the spawned sessions can read.
if [ -f "$goal" ]; then
  goal_abs="$(readlink -f "$goal")"
elif [ -f "$repo/$goal" ]; then
  goal_abs="$(readlink -f "$repo/$goal")"
else
  echo "goal file not found: $goal" >&2; exit 1
fi

command -v tmux >/dev/null   || { echo "tmux not installed" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude not on PATH" >&2; exit 1; }

# Model per role. These are local subscription sessions, so the default errs
# toward the best model (Opus) for every role; drop a role to a faster, cheaper
# model only when you want speed over depth on that role. (Cost-conscious model
# tiering belongs on API-paid remote agents, not here; see README "Cost".)
# Empty string => inherit the user's default.
model_for() {
  case "$1" in
    # Example speed override: uncomment to run mechanical roles faster.
    # tester*|devops*) echo "sonnet" ;;
    *) echo "opus" ;;
  esac
}

mkdir -p "$TEAM_DIR"

# Pre-trust the working tree so interactive roles don't stop at Claude Code's
# workspace-trust prompt (auto-skipped only in -p mode, which roles can't use).
if ! python3 - "$workdir_abs" <<'PY' 2>/dev/null
import json, os, sys
abs = sys.argv[1]
try:
    d = json.load(open(os.path.expanduser("~/.claude.json")))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("projects", {}).get(abs, {}).get("hasTrustDialogAccepted") else 1)
PY
then
  if "$repo/bin/trust-workdir.sh" "$workdir_abs" >/dev/null 2>&1; then
    echo "pre-trusted workdir: $workdir_abs"
  else
    echo "note: could not pre-trust $workdir_abs; roles may show a one-time trust prompt"
  fi
fi

# Reap dead entries from a previous run so teardown never group-kills a recycled
# pid; keep live entries so a second launch can add roles to a running team.
if [ -f "$TEAM_DIR/active" ]; then
  _tmp="$TEAM_DIR/active.$$"; : > "$_tmp"
  while IFS=$'\t' read -r _pid _wid _role; do
    [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null \
      && printf '%s\t%s\t%s\n' "$_pid" "$_wid" "$_role" >> "$_tmp"
  done < "$TEAM_DIR/active"
  mv "$_tmp" "$TEAM_DIR/active"
fi

# Any role can be specified on the fly. If a role has no roles/<base>.md, create
# one from roles/_TEMPLATE.md (a generic, ready-to-use role prompt) so a novel
# role (ux-designer, android, lawyer, researcher, ...) never dead-ends the launch.
# The orchestrator is expected to author a tailored role file first for quality;
# this is the safety net.
ensure_role_file() {
  local base="$1" f="$repo/roles/$1.md" tpl="$repo/roles/_TEMPLATE.md"
  [ -f "$f" ] && return 0
  if [ -f "$tpl" ]; then
    sed "s/{{ROLE}}/$base/g" "$tpl" > "$f"
    echo "auto-created roles/$base.md from _TEMPLATE.md (generic role; refine as needed)" >&2
  else
    printf '# Role: %s\n\nYou are the "%s" on an orchestrated Claude Code team. Bring the expertise of a\nprofessional %s to the assigned unit. Read the goal and your task brief first,\ncoordinate over /is (status:/done:/question:/answer:), stay in your lane, keep\nchanges in scope, and report done: with evidence. Run\n$ORCH_HOME/bin/check-scope.sh <unit> before reporting done.\n' \
      "$base" "$base" "$base" > "$f"
    echo "auto-created roles/$base.md (no _TEMPLATE.md found; minimal prompt)" >&2
  fi
}

# Validate every role up front so a bad name never leaves a half-spawned team.
# A missing role file is created on the fly (see ensure_role_file), not an error.
for role in "$@"; do
  printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$' \
    || { echo "invalid bus name '$role' (must match ^[a-z0-9][a-z0-9-]{0,39}\$)" >&2; exit 1; }
  b="$(printf '%s' "$role" | sed 's/[0-9]*$//')"
  ensure_role_file "$b"
done

start_one() {
  local role="$1"
  local base rolefile rolefile_abs model model_flag pf launch
  # Bus names must satisfy the /is regex; reject bad names deterministically
  # rather than letting a bad spawn fail opaquely downstream.
  if ! printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$'; then
    echo "invalid bus name '$role' (must match ^[a-z0-9][a-z0-9-]{0,39}\$)" >&2; return 1
  fi
  base="$(printf '%s' "$role" | sed 's/[0-9]*$//')"
  rolefile="roles/$base.md"
  ensure_role_file "$base"
  rolefile_abs="$repo/$rolefile"

  model="$(model_for "$role")"
  model_flag=""
  [ -n "$model" ] && model_flag="--model $model"

  # Write the initial prompt to a file; keeps shell quoting simple and the
  # prompt thin (the substance lives in CLAUDE.md, the role file, and the goal).
  pf="$TEAM_DIR/$role.prompt"
  cat >"$pf" <<EOF
You are "$role" on an orchestrated Claude Code dev team.
Your working tree (the code you operate on) is: $workdir_abs
The team's scripts, templates, task briefs, and .team/ artifacts live at
\$ORCH_HOME ($repo), exported in your env. Run gates as \$ORCH_HOME/bin/... and
write team artifacts under \$ORCH_HOME/.team/. Your own code changes go in the
working tree above.
Do these in order:
1. Join the bus:   /is c $role
2. Read these files: \$ORCH_HOME/CLAUDE.md, $rolefile_abs, and the goal at $goal_abs
3. Report ready:   /is s orchestrator 'status: $role ready'
4. Then act on instructions that arrive over the bus. Report progress and
   completion with /is, using status:/done:/question:/answer: prefixes. Stay
   within your role. Send anything longer than a sentence as a file pointer.
EOF

  launch="cd $(printf %q "$workdir_abs")"
  launch="$launch && export ORCH_HOME=$(printf %q "$repo")"
  [ -n "${INTER_SESSION_PORT:-}" ] && \
    launch="$launch && export INTER_SESSION_PORT=$(printf %q "$INTER_SESSION_PORT")"
  [ -n "${INTER_SESSION_IDLE_MINUTES:-}" ] && \
    launch="$launch && export INTER_SESSION_IDLE_MINUTES=$(printf %q "$INTER_SESSION_IDLE_MINUTES")"
  [ -n "${TEAM_RUN_ID:-}" ] && \
    launch="$launch && export TEAM_RUN_ID=$(printf %q "$TEAM_RUN_ID")"
  launch="$launch && exec claude $flags $model_flag \"\$(cat $(printf %q "$pf"))\""

  # Record pane_pid + window id so stop-team.sh can kill exactly what we spawned.
  # claude ignores SIGHUP and survives pty teardown, so killing the tmux window
  # alone does not stop it; teardown signals the pane's process group by pid.
  # tmux setsid's each pane, so pane_pid is the group leader (claude after exec),
  # and its children (MCP servers) share the group.
  # All team tmux runs on the dedicated socket (see team-env.sh). Add a window to
  # the team session if it exists, else create it detached. The -d on new-window
  # keeps the current window (the orchestrator) focused, so spawning roles does
  # not yank an attached operator into each new role window.
  local info pid wid
  if tmux has-session -t "$session" 2>/dev/null; then
    info="$(tmux new-window -d -t "$session" -P -F '#{pane_pid} #{window_id}' -n "$role" "bash -lc $(printf %q "$launch")")"
  else
    info="$(tmux new-session -d -s "$session" -P -F '#{pane_pid} #{window_id}' -n "$role" "bash -lc $(printf %q "$launch")")"
  fi
  pid="${info%% *}"; wid="${info##* }"
  printf '%s\t%s\t%s\n' "$pid" "$wid" "$role" >> "$TEAM_DIR/active"
  echo "launched $role (pid $pid, role: $rolefile, model: ${model:-default}, workdir: $workdir_abs)"
}

for role in "$@"; do
  start_one "$role"
  sleep 1   # stagger starts to ease the rate limit on a cold team
done

echo
echo "Roles running in tmux session '$session' on the team socket '$TEAM_TMUX'."
echo "Watch:  bin/team-status.sh    Attach:  tmux -L $TEAM_TMUX attach -t $session"

# Start the API watchdog (auto-recover transient Anthropic rate-limit / network
# stalls). Pure shell, no claude API calls, so cannot itself be rate-limited.
# Set API_WATCHDOG_DISABLED=1 to skip.
if [ "${API_WATCHDOG_DISABLED:-0}" != "1" ] && [ -x "$repo/bin/api-watchdog.sh" ]; then
  mkdir -p "$TEAM_DIR"
  nohup "$repo/bin/api-watchdog.sh" >"$TEAM_DIR/api-watchdog.log" 2>&1 &
  echo "$!" > "$TEAM_DIR/api-watchdog.pid"
  echo "api-watchdog started (pid $!, log: $TEAM_DIR/api-watchdog.log)"
fi

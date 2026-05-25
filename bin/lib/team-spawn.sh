# team-spawn.sh: the single-role spawn path, sourced (not executed) by
# launch-team.sh (initial team) and add-role.sh (B9 mid-run grow), so a role is
# brought up identically however the team grows.
#
# Requires team-env.sh already sourced (TEAM_DIR, TEAM_SESSION, INTER_SESSION_PORT,
# the tmux() wrapper). The caller MUST set these globals before calling start_one:
#   repo         absolute path of this clone ($ORCH_HOME)
#   workdir_abs  resolved working tree the role operates on
#   goal_abs     resolved absolute path of the goal file
#   session      tmux session name (== TEAM_SESSION)
#   flags        claude flags string (e.g. --dangerously-skip-permissions)
# Optional, propagated into the spawned session if set in the caller's env:
#   INTER_SESSION_PORT, INTER_SESSION_IDLE_MINUTES, TEAM_RUN_ID

# Resolve a goal argument to an absolute path the spawned session can read: try
# it as given (cwd-relative or absolute), then under $repo. Echoes the abs path,
# or returns 1 if not found.
resolve_goal() {
  local g="$1"
  if [ -f "$g" ]; then readlink -f "$g"
  elif [ -f "$repo/$g" ]; then readlink -f "$repo/$g"
  else return 1; fi
}

# Model per role. Local subscription sessions, so the default errs toward the best
# model (Opus) for every role; drop a role to a faster model only for speed over
# depth. Empty string => inherit the user's default.
model_for() {
  case "$1" in
    # Example speed override: uncomment to run mechanical roles faster.
    # tester*|devops*) echo "sonnet" ;;
    *) echo "opus" ;;
  esac
}

# Any role can be specified on the fly. If a role has no roles/<base>.md, create
# one from roles/_TEMPLATE.md so a novel role never dead-ends the launch. The
# orchestrator is expected to author a tailored role file first for quality; this
# is the safety net.
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

# Pre-trust the working tree so interactive roles don't stop at Claude Code's
# workspace-trust prompt (auto-skipped only in -p mode, which roles can't use).
# Idempotent: a no-op if the dir is already trusted. Takes the abs workdir.
pre_trust_workdir() {
  local wd="$1"
  if python3 - "$wd" <<'PY' 2>/dev/null
import json, os, sys
abs = sys.argv[1]
try:
    d = json.load(open(os.path.expanduser("~/.claude.json")))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("projects", {}).get(abs, {}).get("hasTrustDialogAccepted") else 1)
PY
  then
    return 0
  fi
  if "$repo/bin/trust-workdir.sh" "$wd" >/dev/null 2>&1; then
    echo "pre-trusted workdir: $wd"
  else
    echo "note: could not pre-trust $wd; roles may show a one-time trust prompt"
  fi
}

# Reap dead entries from a previous run so teardown never group-kills a recycled
# pid; keep live entries so a second launch (or add-role) adds rather than
# replaces. Operates on $TEAM_DIR/active in place.
reap_dead_keep_live() {
  [ -f "$TEAM_DIR/active" ] || return 0
  local _tmp="$TEAM_DIR/active.$$"; : > "$_tmp"
  local _pid _wid _role
  # `|| [ -n "$_pid" ]` so a final line without a trailing newline is not dropped.
  # Keep an entry only if its pid is alive AND still a claude process: a recycled
  # pid (claude exited, OS reused the number) must be treated as dead, never kept.
  while IFS=$'\t' read -r _pid _wid _role || [ -n "${_pid:-}" ]; do
    [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null \
      && ps -p "$_pid" -o args= 2>/dev/null | grep -q '[c]laude' \
      && printf '%s\t%s\t%s\n' "$_pid" "$_wid" "$_role" >> "$_tmp"
  done < "$TEAM_DIR/active"
  mv "$_tmp" "$TEAM_DIR/active"
}

# Spawn one role into the team session, record pid+window in $TEAM_DIR/active.
start_one() {
  local role="$1"
  local base rolefile rolefile_abs model model_flag pf launch
  # Bus names must satisfy the /is regex; reject bad names deterministically
  # rather than letting a bad spawn fail opaquely downstream.
  if ! printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]{0,39}$'; then
    echo "invalid bus name '$role' (must match ^[a-z0-9][a-z0-9-]{0,39}\$)" >&2; return 1
  fi
  base="$(printf '%s' "$role" | sed 's/[0-9]*$//')"
  # An all-digits name (e.g. "123") passes the regex but strips to an empty base,
  # which would write a junk roles/.md and a mis-named role. Reject it.
  if [ -z "$base" ]; then
    echo "invalid role '$role': a name needs a non-digit part (the base maps to roles/<base>.md)" >&2
    return 1
  fi
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
The team's scripts and templates live at \$ORCH_HOME ($repo), exported in your
env; run gates as \$ORCH_HOME/bin/... . This run's shared state dir is \$TEAM_DIR
($TEAM_DIR), also exported: write ALL team artifacts (specs, evidence, logs, the
ledger) under \$TEAM_DIR, never under \$ORCH_HOME/.team directly, so parallel runs
in this clone do not collide. Your own code changes go in the working tree above.
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
  # Export this run's state dir so roles write artifacts to the per-run path, not
  # the shared $ORCH_HOME/.team (parallel-run isolation; see BUG-concurrent-runs).
  launch="$launch && export TEAM_DIR=$(printf %q "$TEAM_DIR")"
  [ -n "${INTER_SESSION_PORT:-}" ] && \
    launch="$launch && export INTER_SESSION_PORT=$(printf %q "$INTER_SESSION_PORT")"
  [ -n "${INTER_SESSION_IDLE_MINUTES:-}" ] && \
    launch="$launch && export INTER_SESSION_IDLE_MINUTES=$(printf %q "$INTER_SESSION_IDLE_MINUTES")"
  [ -n "${TEAM_RUN_ID:-}" ] && \
    launch="$launch && export TEAM_RUN_ID=$(printf %q "$TEAM_RUN_ID")"
  launch="$launch && exec ${TEAM_ROLE_CMD:-claude} $flags $model_flag \"\$(cat $(printf %q "$pf"))\""

  # Record pane_pid + window id so teardown can kill exactly what we spawned.
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

# Start the API watchdog for this team, once. Idempotent: if the recorded pid is
# a live api-watchdog process, do nothing (a repeated launch/add must not start a
# second watchdog). Set API_WATCHDOG_DISABLED=1 to skip.
start_api_watchdog() {
  [ "${API_WATCHDOG_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/api-watchdog.sh" ] || return 0
  mkdir -p "$TEAM_DIR"
  local pidf="$TEAM_DIR/api-watchdog.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'api-watchdog'; then
      echo "api-watchdog already running (pid $oldpid)"
      return 0
    fi
  fi
  # 9>&- closes fd 9 in the daemon. add-role.sh / retire-role.sh hold the roster
  # lock on fd 9 (exec 9>...lock); a long-lived daemon that inherited it would
  # keep the open file description alive and the flock would never release,
  # deadlocking every later add/retire. The watchdog must not inherit that fd.
  nohup "$repo/bin/api-watchdog.sh" >"$TEAM_DIR/api-watchdog.log" 2>&1 9>&- &
  echo "$!" > "$pidf"
  echo "api-watchdog started (pid $!, log: $TEAM_DIR/api-watchdog.log)"
}

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

# Model per role: a tiered policy keyed on judgment density. Cost per token
# spans ~10x across tiers (haiku < sonnet < opus < fable, with fable ~2x opus),
# while an IDLE role costs nothing: the expensive state is a large context
# re-read on every turn. So the top tier is reserved for roles whose judgment
# quality bounds the whole run, and mechanical roles ride cheap models with no
# quality loss. Token-economy rationale and tuning guide: docs/model-policy.md.
#
# Tiers (matched on the full role name, digit suffixes included):
#   top   judgment-dense, mistake-expensive: orchestration, operator liaison,
#         adversarial verification (review/test/fact-check), requirements,
#         architecture. Default: fable.
#   mid   produces the work product: code, prose, research, legal analysis,
#         integration, design. Default: opus. Also the fallback for any role
#         not matched below (a novel role is assumed to do real work).
#   cheap mechanical, rule-following, or relay work: sonnet; pure read-only
#         display/polling: haiku.
#
# Overrides, highest precedence first:
#   TEAM_MODEL_<ROLE>    per-role; role name upcased with '-' -> '_'
#                        (e.g. TEAM_MODEL_REVIEWER2=opus)
#   TEAM_MODEL_TOP       model for the top tier (default fable)
#   TEAM_MODEL_DEFAULT   model for the mid tier / unmatched roles (default opus)
# Values are claude --model aliases (fable/opus/sonnet/haiku) or full model ids.
# An empty value => inherit the user's CLI default.
model_for() {
  local role="$1" var
  var="TEAM_MODEL_$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')"
  if [ -n "${!var:-}" ]; then printf '%s\n' "${!var}"; return 0; fi
  case "$role" in
    orchestrator|communicator*|user-communicator*) echo "${TEAM_MODEL_TOP:-fable}" ;;
    reviewer*|peer-reviewer*|tester*|fact-checker*|architect*|analyst*)
      echo "${TEAM_MODEL_TOP:-fable}" ;;
    devops*|copy-editor*|paralegal*|doc-integrator*) echo "sonnet" ;;
    dashboard*|relay*|poller*) echo "haiku" ;;
    *) echo "${TEAM_MODEL_DEFAULT:-opus}" ;;
  esac
}

# Record the model a role was launched on, so the observer and the compaction
# watchdog read ground truth from disk instead of parsing live process args.
record_role_model() {
  local role="$1" model="$2"
  mkdir -p "$TEAM_DIR/models"
  printf '%s\n' "${model:-default}" > "$TEAM_DIR/models/$role"
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
  record_role_model "$role" "$model"

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
2. Tool-IO self-check (born-corrupt guard). Run this one Bash command:
      echo ${role}_TOOLIO_$$
   The stdout MUST be exactly that token. If instead you get a Read-style "File
   does not exist" error, the raw command text echoed back, or any garbled or
   contradictory output, your tool I/O is corrupted (a known rare failure in a
   freshly spawned session under load). Do NOT try to work. Signal it over the
   bus, which stays reliable even when the Bash/Read tools are corrupted:
      /is s orchestrator 'status: $role BORN-CORRUPT, retire+respawn me'
   then stop and wait. Only continue past this step if the echo was clean.
3. Read these files: \$ORCH_HOME/CLAUDE.md, $rolefile_abs, and the goal at $goal_abs
4. Report ready:   /is s orchestrator 'status: $role ready'
5. Then act on instructions that arrive over the bus. Report progress and
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
    # Stale-pidfile / pid-reuse guard: treat the pid as "already running" ONLY if
    # it is ACTUALLY this daemon. Match the exec'd script PATH (bin/api-watchdog.sh),
    # not a bare name -- a recycled pid running `grep api-watchdog`, `tail
    # ...api-watchdog.log`, or another run's daemon must NOT false-positive, or a
    # dead daemon would never be relaunched (the bug that left both watchdogs dead
    # while ensure thought they were alive).
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'bin/api-watchdog\.sh'; then
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

# Start the compaction watchdog for this team, once. It keeps the orchestrator's
# context off the auto-compact ceiling by compacting it early at idle task
# boundaries, so the run spends most of its life in a small, cheap context instead
# of repeatedly re-reading a near-full one (see bin/compaction-watchdog.sh). Set
# COMPACT_WATCHDOG_DISABLED=1 to skip. Single-instance via pgrep (so it also will
# not duplicate an instance brought up by an external keepalive, e.g. cron).
start_compaction_watchdog() {
  [ "${COMPACT_WATCHDOG_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/compaction-watchdog.sh" ] || return 0
  mkdir -p "$TEAM_DIR"
  if pgrep -f 'bin/compaction-watchdog\.sh' >/dev/null 2>&1; then
    echo "compaction-watchdog already running"
    return 0
  fi
  # 9>&- for the same flock reason as start_api_watchdog. Pass the team's socket,
  # session and log so it targets this team's orchestrator and logs under TEAM_DIR.
  COMPACT_SOCKET="$TEAM_TMUX" COMPACT_SESSION="$TEAM_SESSION" \
    COMPACT_LOG="$TEAM_DIR/compaction-watchdog.log" \
    nohup "$repo/bin/compaction-watchdog.sh" >/dev/null 2>&1 9>&- &
  echo "$!" > "$TEAM_DIR/compaction-watchdog.pid"
  echo "compaction-watchdog started (pid $!, log: $TEAM_DIR/compaction-watchdog.log)"
}

# Start the tmux-watchdog for this team, once. Idempotent same way as the api
# watchdog. Set TMUX_WATCHDOG_DISABLED=1 to skip. This is the May-2026 fix:
# detect a dead tmux server fast, snapshot the team state for forensics, push
# ntfy on transitions, drop a CRASH-DETECTED.md so the operator's side notices.
start_tmux_watchdog() {
  [ "${TMUX_WATCHDOG_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/tmux-watchdog.sh" ] || return 0
  mkdir -p "$TEAM_DIR"
  local pidf="$TEAM_DIR/tmux-watchdog.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    # pid-reuse guard: match the exec'd script PATH, not a bare name (see start_api_watchdog).
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'bin/tmux-watchdog\.sh'; then
      echo "tmux-watchdog already running (pid $oldpid)"
      return 0
    fi
  fi
  nohup "$repo/bin/tmux-watchdog.sh" >"$TEAM_DIR/tmux-watchdog.log" 2>&1 9>&- &
  echo "$!" > "$pidf"
  echo "tmux-watchdog started (pid $!, log: $TEAM_DIR/tmux-watchdog.log)"
}

# Start the efficiency observer for this team, once. Idempotent same way as the
# watchdogs. Set OBSERVER_DISABLED=1 to skip. Unlike the watchdogs (mechanical
# stall/crash recovery), the observer periodically asks a model whether the team
# should grow or shrink and whether the host is right-sized, and nudges the
# orchestrator; it recommends, never acts.
start_observer() {
  [ "${OBSERVER_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/observer.sh" ] || return 0
  mkdir -p "$TEAM_DIR"
  local pidf="$TEAM_DIR/observer.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    # pid-reuse guard: match the exec'd script PATH, not a bare name (see start_api_watchdog).
    # 'observer' as a bare substring is especially collision-prone.
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'bin/observer\.sh'; then
      echo "observer already running (pid $oldpid)"
      return 0
    fi
  fi
  nohup "$repo/bin/observer.sh" >"$TEAM_DIR/observer.log" 2>&1 9>&- &
  echo "$!" > "$pidf"
  echo "observer started (pid $!, log: $TEAM_DIR/observer.log)"
}

# Ensure the team's supervisor daemons are up. Idempotent; each start_* honors
# its own opt-out env var. This is the ONE canonical set (api-watchdog,
# compaction-watchdog, tmux-watchdog, observer, chrome-supervisor,
# intake-poller), shared by launch-team.sh (cold start), start-orchestrator.sh
# (recovery path) and add-role.sh (mid-run grow), so no path leaves a different
# set running. The dashboard is deliberately not here: observability only, with
# its own operator prompt in launch-team.sh.
ensure_team_daemons() {
  start_api_watchdog || true
  start_compaction_watchdog || true
  start_tmux_watchdog || true
  start_observer || true
  start_chrome_supervisor || true
  start_intake_poller || true
}

# Start the chrome-devtools supervisor for this team, once. Idempotent same way as
# the watchdogs. Set CHROME_SUPERVISOR_DISABLED=1 to skip. It reaps orphaned
# Chrome/MCP debris (dead-owner processes reparented to init) and, when the
# api-watchdog has marked a role stuck on a hung tool call, kills that role's
# Chrome so the MCP's frozen op rejects and the browser relaunches, recovering
# the role in seconds instead of waiting out a full retire+respawn. A no-op unless
# bin/chrome-supervisor.sh is present.
start_chrome_supervisor() {
  [ "${CHROME_SUPERVISOR_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/chrome-supervisor.sh" ] || return 0
  mkdir -p "$TEAM_DIR"
  local pidf="$TEAM_DIR/chrome-supervisor.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    # pid-reuse guard: match the exec'd script PATH, not a bare name (see start_api_watchdog).
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'bin/chrome-supervisor\.sh'; then
      echo "chrome-supervisor already running (pid $oldpid)"
      return 0
    fi
  fi
  nohup "$repo/bin/chrome-supervisor.sh" >"$TEAM_DIR/chrome-supervisor.log" 2>&1 9>&- &
  echo "$!" > "$pidf"
  echo "chrome-supervisor started (pid $!, log: $TEAM_DIR/chrome-supervisor.log)"
}

# Start the project's optional intake poller for this team, once. Idempotent
# same way as the watchdogs; opt-out INTAKE_POLLER_DISABLED=1. An intake poller
# is a small, project-provided daemon that watches an external surface (email,
# chat, a ticket queue, ...) and pings the `orchestrator` bus peer on new
# traffic, so a team can react to the outside world. The engine only binds its
# LIFECYCLE to the team's: the poller needs the per-run /is bus and is useless
# without a live team, so it is team-scoped, never a standalone systemd service.
# Resolve the script from $INTAKE_POLLER, else <working-tree>/scripts/poller.py.
# Most teams ship none; that is fine (the function just returns). The orchestrator
# can suggest the operator add one when a goal needs external intake.
start_intake_poller() {
  [ "${INTAKE_POLLER_DISABLED:-0}" = "1" ] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local poller="${INTAKE_POLLER:-}"
  if [ -z "$poller" ] && [ -f "$repo/project.conf" ]; then
    local WORKDIR="" INTAKE_POLLER=""
    # shellcheck disable=SC1091
    . "$repo/project.conf" 2>/dev/null || true
    [ -z "$poller" ] && poller="${INTAKE_POLLER:-}"
    [ -z "$poller" ] && [ -n "$WORKDIR" ] && poller="$WORKDIR/scripts/poller.py"
  fi
  [ -n "$poller" ] && [ -f "$poller" ] || return 0
  mkdir -p "$TEAM_DIR"
  local pidf="$TEAM_DIR/intake-poller.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q 'poller'; then
      echo "intake-poller already running (pid $oldpid)"
      return 0
    fi
  fi
  nohup python3 "$poller" --peer orchestrator >"$TEAM_DIR/intake-poller.log" 2>&1 9>&- &
  echo "$!" > "$pidf"
  echo "intake-poller started (pid $!, poller: $poller, log: $TEAM_DIR/intake-poller.log)"
}

# Ask the operator whether to bring up the visual dashboard. Sits in front of
# start_dashboard, never replaces its guard. Precedence (highest first):
#
#   1) DASHBOARD_DISABLED=1 in env  ->  skip without asking. The env wins so
#      scripted callers (CI, automated launches, the watchdog respawning) keep
#      their existing opt-out path.
#   2) Otherwise prompt "Show the visual dashboard? [Y/n]" with a 5 s timeout.
#      On a TTY the prompt is visible. On non-TTY stdin (redirect from
#      /dev/null, here-doc, process substitution) the visible prompt is
#      suppressed, but `read -t 5` still runs so a piped Y / n answer is
#      honoured by the smoke harness. EOF or timeout falls back to the Y
#      default and the dashboard starts.
#   3) Answer N / n exports DASHBOARD_DISABLED=1 for the rest of the launch so
#      every later code path that checks the env sees the same opt-out signal.
#      Answer Y / empty leaves the env alone and start_dashboard runs.
prompt_dashboard_choice() {
  if [ "${DASHBOARD_DISABLED:-0}" = "1" ]; then
    echo "dashboard: skipped (DASHBOARD_DISABLED=1)"
    return 0
  fi
  if [ -t 0 ]; then
    printf 'Show the visual dashboard? [Y/n] '
  fi
  local ans=""
  if ! read -r -t 5 ans; then
    # read failed: 5 s timeout on a quiet TTY, or EOF from /dev/null. Either
    # way, no answer -> Y default. Newline closes the prompt line on TTY.
    [ -t 0 ] && echo
    if [ -t 0 ]; then
      echo "dashboard: accepted (timeout, default Y)"
    else
      echo "dashboard: prompt skipped (non-tty, default Y)"
    fi
    return 0
  fi
  case "$ans" in
    [Nn]|[Nn][Oo])
      export DASHBOARD_DISABLED=1
      echo "dashboard: declined; DASHBOARD_DISABLED=1 for this launch"
      ;;
    "")
      echo "dashboard: accepted (default Y)"
      ;;
    *)
      echo "dashboard: accepted ($ans)"
      ;;
  esac
}

# Start the B11 visual dashboard for this team, once. Same shape as the api
# watchdog: idempotent (skip if recorded pid is alive), opt-out via
# DASHBOARD_DISABLED=1, port override via DASHBOARD_PORT. Read-only HTTP server
# bound to 127.0.0.1 — second-screen view of a live run. Cleaned up by
# stop-team.sh / panic.sh / cleanup.sh.
start_dashboard() {
  [ "${DASHBOARD_DISABLED:-0}" = "1" ] && return 0
  [ -x "$repo/bin/dashboard.sh" ] || return 0
  mkdir -p "$TEAM_DIR"
  local pidf="$TEAM_DIR/dashboard.pid" oldpid
  if [ -f "$pidf" ]; then
    oldpid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null \
       && ps -p "$oldpid" -o args= 2>/dev/null | grep -q '[d]ashboard/server/server.py'; then
      echo "dashboard already running (pid $oldpid)"
      return 0
    fi
  fi
  # 9>&- for the same flock reason as start_api_watchdog. The dashboard inherits
  # TEAM_DIR from the environment, so it observes THIS run.
  nohup "$repo/bin/dashboard.sh" --port "${DASHBOARD_PORT:-0}" \
        >"$TEAM_DIR/dashboard.log" 2>&1 9>&- &
  local dpid=$!
  echo "$dpid" > "$pidf"
  # Wait briefly for the server to bind and write its URL on the first log line.
  local i url=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$dpid" 2>/dev/null; then break; fi
    url="$(grep -oE 'http://127\.0\.0\.1:[0-9]+/' "$TEAM_DIR/dashboard.log" 2>/dev/null | head -1)"
    [ -n "$url" ] && break
    sleep 0.2
  done
  if [ -n "$url" ]; then
    echo "$url" > "$TEAM_DIR/dashboard.url"
    echo "dashboard started (pid $dpid) — open ${url}  (log: $TEAM_DIR/dashboard.log)"
  else
    echo "dashboard started (pid $dpid, log: $TEAM_DIR/dashboard.log; URL not captured yet)"
  fi
}

#!/usr/bin/env bash
# B9 dynamic-team-scaling test suite. Drives bin/add-role.sh and
# bin/retire-role.sh (and the refactored launch-team.sh) as black boxes against
# an ISOLATED, stub-backed team, then asserts on the resulting tmux/active/ledger
# state.
#
# Isolation & safety:
#   - Runs under a dedicated TEAM_RUN_ID, so the team gets its own derived bus
#     port (9500-9899), tmux session, and state dir (.team-<id>/). It never uses
#     the default /is bus (9473).
#   - Roles are the stub at tests/b9/bin/claude (TEAM_ROLE_CMD), so NO real
#     claude starts and NO /is bus server is ever spawned.
#   - Aborts before doing anything if the derived port is 9473 (the default bus).
#   - An EXIT trap always tears the test team down.
#
# Usage: tests/b9/run-tests.sh [-v]   (-v echoes failing command output)

set -u
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
stub="$here/bin/claude"
[ -x "$stub" ] || { chmod +x "$stub" 2>/dev/null || { echo "stub not executable: $stub" >&2; exit 2; }; }

export TEAM_RUN_ID="${TEAM_RUN_ID:-b9test}"
export TEAM_ROLE_CMD="$stub"
unset NTFY_URL   # never push to the operator's real ntfy topic during tests
GOAL="goals/repo-bugfix.md"
[ -f "$repo/$GOAL" ] || GOAL="goals/_TEMPLATE.md"

# Source env to learn TEAM_DIR/SESSION/PORT and get the tmux() wrapper + roster
# helpers for inspection.
# shellcheck source=/dev/null
. "$repo/bin/team-env.sh"
# shellcheck source=/dev/null
. "$repo/bin/lib/roster.sh"

# --- HARD SAFETY GATE: never run against the default /is bus ------------------
if [ "$TEAM_PORT" = "9473" ]; then
  echo "ABORT: derived TEAM_PORT is 9473 (the default /is bus). Pick another TEAM_RUN_ID." >&2
  exit 2
fi
echo "== B9 suite  run-id=$TEAM_RUN_ID  session=$TEAM_SESSION  port=$TEAM_PORT  dir=$TEAM_DIR"
echo "== stub claude: $stub   goal: $GOAL"

# Baseline of the default-bus pidfile, so we can prove the suite never touches it.
BUS9473="$HOME/.claude/data/inter-session/server.9473.pid"
b9473_before="absent"; [ -f "$BUS9473" ] && b9473_before="$(cksum "$BUS9473" 2>/dev/null)"

P=0; F=0; declare -a FAILED=()
# Both return 0 so the `cond && fail || pass` idiom can never run BOTH branches
# (a nonzero fail would otherwise trigger the `|| pass`).
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; P=$((P+1)); return 0; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; F=$((F+1)); FAILED+=("$1"); [ "$VERBOSE" = 1 ] && [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
expect_rc(){ [ "$2" = "$1" ] && pass "$3" || fail "$3 (want rc=$1 got $2)" "${4:-}"; }
expect_ne_rc(){ [ "$2" != "$1" ] && pass "$3" || fail "$3 (rc unexpectedly $1)" "${4:-}"; }
expect_eq(){ [ "$1" = "$2" ] && pass "$3" || fail "$3 (want '$1' got '$2')" "${4:-}"; }
expect_contains(){ case "$1" in *"$2"*) pass "$3";; *) fail "$3 (missing '$2')" "$1";; esac; }
expect_missing(){ case "$1" in *"$2"*) fail "$3 (unexpected '$2')" "$1";; *) pass "$3";; esac; }
expect_alive(){ kill -0 "$1" 2>/dev/null && pass "$2" || fail "$2 (pid $1 dead)"; }
expect_dead(){ kill -0 "$1" 2>/dev/null && fail "$2 (pid $1 still alive)" || pass "$2"; }
expect_file_has(){ grep -qF -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3 (no '$2' in $1)"; }

add(){ ( cd "$repo" && ./bin/add-role.sh "$@" ) 2>&1; }
retire(){ ( cd "$repo" && ./bin/retire-role.sh "$@" ) 2>&1; }
launch(){ ( cd "$repo" && ./bin/launch-team.sh "$@" ) 2>&1; }
win_exists(){ tmux list-windows -t "$TEAM_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$1"; }
role_pid(){ local p w r; while IFS=$'\t' read -r p w r; do [ "$r" = "$1" ] && echo "$p"; done < "$TEAM_DIR/active" 2>/dev/null | tail -1; }
role_wid(){ local p w r; while IFS=$'\t' read -r p w r; do [ "$r" = "$1" ] && echo "$w"; done < "$TEAM_DIR/active" 2>/dev/null | tail -1; }

# Snapshot the tracked role files so cleanup can remove any that the suite's
# novel test role names cause ensure_role_file to auto-create (capguard, crashy,
# etlworker, ...), without touching pre-existing roles.
ROLES_BEFORE="$(cd "$repo/roles" 2>/dev/null && ls *.md 2>/dev/null | sort || true)"

cleanup(){
  echo "== teardown"
  if [ -f "$TEAM_DIR/active" ]; then
    while IFS=$'\t' read -r p w r || [ -n "${p:-}" ]; do [ -n "${p:-}" ] && { kill -KILL "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; }; done < "$TEAM_DIR/active"
  fi
  [ -f "$TEAM_DIR/api-watchdog.pid" ] && kill -KILL "$(cat "$TEAM_DIR/api-watchdog.pid" 2>/dev/null)" 2>/dev/null
  tmux kill-session -t "$TEAM_SESSION" 2>/dev/null
  pkill -KILL -f "$stub" 2>/dev/null   # sweep any stray stub roles from this suite
  rm -rf "$TEAM_DIR"
  # Remove role files the suite created (anything in roles/ not in the snapshot).
  local now f
  now="$(cd "$repo/roles" 2>/dev/null && ls *.md 2>/dev/null | sort || true)"
  for f in $(comm -13 <(printf '%s\n' "$ROLES_BEFORE") <(printf '%s\n' "$now") 2>/dev/null); do
    rm -f "$repo/roles/$f"
  done
}
trap cleanup EXIT

# Start clean even if a previous run left state.
cleanup >/dev/null 2>&1; trap cleanup EXIT

echo; echo "--- T1: add-role refuses when no team is live"
out="$(add "$GOAL" implementer1)"; rc=$?
expect_ne_rc 0 "$rc" "T1 rc nonzero"
expect_contains "$out" "no live team" "T1 explains no live team"

echo; echo "--- T2: launch initial team (refactored launch-team via stub)"
out="$(launch "$GOAL" architect implementer1)"; rc=$?
expect_rc 0 "$rc" "T2 launch rc=0" "$out"
sleep 1
expect_eq 2 "$(live_role_count)" "T2 two live roles recorded"
win_exists architect && pass "T2 architect window" || fail "T2 architect window"
win_exists implementer1 && pass "T2 implementer1 window" || fail "T2 implementer1 window"
WD="$(cat "$TEAM_DIR/api-watchdog.pid" 2>/dev/null)"
[ -n "$WD" ] && expect_alive "$WD" "T2 api-watchdog started" || fail "T2 api-watchdog pidfile"
# Roles must inherit TEAM_DIR (per-run artifact path; concurrency-bug fix).
apid="$(role_pid architect)"
if [ -n "$apid" ] && tr '\0' '\n' < "/proc/$apid/environ" 2>/dev/null | grep -qxF "TEAM_DIR=$TEAM_DIR"; then
  pass "T2 role inherits TEAM_DIR ($TEAM_DIR)"
else
  fail "T2 role inherits TEAM_DIR"
fi

echo; echo "--- T3: api-watchdog start is idempotent (second launch adds a role, no 2nd watchdog)"
out="$(launch "$GOAL" reviewer1)"; rc=$?
expect_rc 0 "$rc" "T3 second launch rc=0" "$out"
WD2="$(cat "$TEAM_DIR/api-watchdog.pid" 2>/dev/null)"
expect_eq "$WD" "$WD2" "T3 watchdog pid unchanged"
n_wd="$(pgrep -f "api-watchdog.sh" 2>/dev/null | while read -r q; do tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | grep -qx "TEAM_RUN_ID=$TEAM_RUN_ID" && echo "$q"; done | wc -l)"
expect_eq 1 "$n_wd" "T3 exactly one watchdog for this run"
expect_eq 3 "$(live_role_count)" "T3 three live roles (reviewer1 added)"

echo; echo "--- T4: add-role happy path"
before="$(live_role_count)"
out="$(add "$GOAL" tester1 --reason 'need a test pass')"; rc=$?
expect_rc 0 "$rc" "T4 add rc=0" "$out"
sleep 1
expect_eq $((before+1)) "$(live_role_count)" "T4 live count +1"
win_exists tester1 && pass "T4 tester1 window" || fail "T4 tester1 window"
expect_contains "$out" "added tester1" "T4 stdout notice"
expect_file_has "$TEAM_DIR/state.md" "added tester1" "T4 decision-log line"
expect_file_has "$TEAM_DIR/state.md" "+tester1" "T4 roster line"

echo; echo "--- T5: double-spawn refused"
out="$(add "$GOAL" tester1)"; rc=$?
expect_ne_rc 0 "$rc" "T5 rc nonzero"
expect_contains "$out" "already live" "T5 explains already live"

echo; echo "--- T6: invalid bus name refused"
out="$(add "$GOAL" 'Bad_Name')"; rc=$?
expect_ne_rc 0 "$rc" "T6 rc nonzero"
expect_contains "$out" "invalid bus name" "T6 explains invalid name"

echo; echo "--- T7: missing goal refused"
out="$(add "/no/such/goal.md" lawyer1)"; rc=$?
expect_ne_rc 0 "$rc" "T7 rc nonzero"
expect_contains "$out" "goal file not found" "T7 explains missing goal"

echo; echo "--- T8: bad task brief refused"
out="$(add "$GOAL" lawyer1 --task /no/such/brief.md)"; rc=$?
expect_ne_rc 0 "$rc" "T8 rc nonzero"
expect_contains "$out" "task brief not found" "T8 explains missing brief"

echo; echo "--- T9: --auto-number picks next free + reuse-before-spawn hint"
before="$(live_role_count)"
out="$(add "$GOAL" implementer --auto-number --reason 'parallelise')"; rc=$?
expect_rc 0 "$rc" "T9 add rc=0" "$out"
sleep 1
expect_contains "$out" "implementer2" "T9 auto-numbered to implementer2"
win_exists implementer2 && pass "T9 implementer2 window" || fail "T9 implementer2 window"
expect_contains "$out" "already on the team" "T9 reuse-before-spawn hint shown"
expect_eq $((before+1)) "$(live_role_count)" "T9 live count +1"

echo; echo "--- T10: soft cap via MAX_TEAM_SIZE env"
cur="$(live_role_count)"
out="$( cd "$repo" && MAX_TEAM_SIZE="$cur" ./bin/add-role.sh "$GOAL" capguard1 2>&1 )"; rc=$?
expect_ne_rc 0 "$rc" "T10 refused at cap"
expect_contains "$out" "at the cap" "T10 explains cap"
expect_eq "$cur" "$(live_role_count)" "T10 no role added at cap"
out="$( cd "$repo" && MAX_TEAM_SIZE="$((cur+1))" ./bin/add-role.sh "$GOAL" capguard1 2>&1 )"; rc=$?
expect_rc 0 "$rc" "T10 allowed at cap+1" "$out"
sleep 1
expect_eq "$((cur+1))" "$(live_role_count)" "T10 role added under raised cap"

echo; echo "--- T10b: soft cap via \$TEAM_DIR/max-team-size file, uncapped, and precedence"
cur="$(live_role_count)"
echo "$cur" > "$TEAM_DIR/max-team-size"           # file cap = current live count
out="$(add "$GOAL" capfile1)"; rc=$?
expect_ne_rc 0 "$rc" "T10b file cap refuses at limit"
expect_contains "$out" "cap $cur" "T10b refusal cites the file cap"
echo "none" > "$TEAM_DIR/max-team-size"           # uncapped
out="$(add "$GOAL" capfile1 --reason 'uncapped add')"; rc=$?
expect_rc 0 "$rc" "T10b uncapped (none) allows add past would-be cap" "$out"
expect_contains "$out" "uncapped" "T10b notice says uncapped"
sleep 1
# precedence: env MAX_TEAM_SIZE beats the file (file says uncapped, env enforces)
now="$(live_role_count)"
out="$( cd "$repo" && MAX_TEAM_SIZE="$now" ./bin/add-role.sh "$GOAL" capfile2 2>&1 )"; rc=$?
expect_ne_rc 0 "$rc" "T10b env MAX_TEAM_SIZE overrides the file (refuses though file=none)"
rm -f "$TEAM_DIR/max-team-size"                   # back to default 12 for later tests
# retire the cap-probe roles so the roster stays small for the rest of the suite
retire capguard1 --no-graceful --no-ntfy >/dev/null 2>&1
retire capfile1  --no-graceful --no-ntfy >/dev/null 2>&1

echo; echo "--- T11: retire refuses a role with in-flight units (work not dropped)"
# Give tester1 an in-progress unit in the ledger.
cat >> "$TEAM_DIR/state.md" <<'EOF'

## unit: testpass
owner: tester1
status: in-progress
notes: mid-run
EOF
tp="$(role_pid tester1)"
out="$(retire tester1 --reason 'done')"; rc=$?
expect_ne_rc 0 "$rc" "T11 refused (in-flight)"
expect_contains "$out" "in-flight" "T11 explains in-flight"
expect_alive "$tp" "T11 tester1 still alive after refusal"
win_exists tester1 && pass "T11 tester1 window intact" || fail "T11 tester1 window gone"

echo; echo "--- T12: retire --force re-files the unit and tears the role down"
tp="$(role_pid tester1)"; tw="$(role_wid tester1)"
# capture the stub's MCP child to prove group kill
child="$(pgrep -P "$tp" 2>/dev/null | head -1)"
out="$(retire tester1 --reason 'wrapping up' --force --no-graceful)"; rc=$?
expect_rc 0 "$rc" "T12 force retire rc=0" "$out"
sleep 1
expect_dead "$tp" "T12 tester1 leader killed"
[ -n "$child" ] && expect_dead "$child" "T12 stub MCP child killed (group kill)" || pass "T12 (no child captured)"
win_exists tester1 && fail "T12 tester1 window closed" || pass "T12 tester1 window closed"
role_is_live tester1 && fail "T12 tester1 removed from active" || pass "T12 tester1 removed from active"
expect_file_has "$TEAM_DIR/state.md" "status: todo" "T12 unit re-filed to todo"
grep -A3 '## unit: testpass' "$TEAM_DIR/state.md" | grep -q 'owner: -' && pass "T12 unit owner cleared" || fail "T12 unit owner cleared"
[ -f "$TEAM_DIR/retired/tester1/retired-at" ] && pass "T12 archived to retired/" || fail "T12 archive dir"
expect_file_has "$TEAM_DIR/state.md" "retired tester1" "T12 decision-log retire line"
expect_file_has "$TEAM_DIR/state.md" "-tester1" "T12 roster retire line"

echo; echo "--- T13: retire happy path (no units) is scoped (siblings untouched)"
ap="$(role_pid architect)"; ip="$(role_pid implementer1)"
out="$(retire reviewer1 --reason 'review done' --no-graceful)"; rc=$?
expect_rc 0 "$rc" "T13 retire rc=0" "$out"
sleep 1
role_is_live reviewer1 && fail "T13 reviewer1 gone" || pass "T13 reviewer1 gone"
expect_alive "$ap" "T13 architect untouched"
expect_alive "$ip" "T13 implementer1 untouched"
win_exists architect && pass "T13 architect window intact" || fail "T13 architect window intact"

echo; echo "--- T14: retire a nonexistent role refused"
out="$(retire ghostrole)"; rc=$?
expect_ne_rc 0 "$rc" "T14 rc nonzero"
expect_contains "$out" "not in the active roster" "T14 explains not present"

echo; echo "--- T15: SIGHUP survival -> retire reaps a window-less role by pid group"
out="$(add "$GOAL" hupcanary --reason 'survival probe')"; rc=$?
expect_rc 0 "$rc" "T15 add canary rc=0" "$out"
sleep 1
cp_="$(role_pid hupcanary)"; cw="$(role_wid hupcanary)"
tmux kill-window -t "$cw" 2>/dev/null
sleep 1
expect_alive "$cp_" "T15 canary survives window kill (HUP-proof)"
out="$(retire hupcanary --reason 'cleanup' --no-graceful)"; rc=$?
expect_rc 0 "$rc" "T15 retire window-less role rc=0" "$out"
sleep 1
expect_dead "$cp_" "T15 retire group-killed the window-less role"
role_is_live hupcanary && fail "T15 canary removed" || pass "T15 canary removed"

echo; echo "--- T16: retire cleans a crashed role's stale entry gracefully"
out="$(add "$GOAL" crashy --reason 'crash probe')"; rc=$?
expect_rc 0 "$rc" "T16 add crashy rc=0" "$out"
sleep 1
xp="$(role_pid crashy)"
kill -KILL "-$xp" 2>/dev/null; kill -KILL "$xp" 2>/dev/null   # simulate a crash, leave the active entry
sleep 1
out="$(retire crashy --reason 'reap' --no-graceful)"; rc=$?
expect_rc 0 "$rc" "T16 retire of dead entry rc=0" "$out"
role_is_live crashy && fail "T16 crashy entry cleaned" || pass "T16 crashy entry cleaned"

echo; echo "--- T17: safety - default /is bus (9473) never touched; no listener on team port"
b9473_after="absent"; [ -f "$BUS9473" ] && b9473_after="$(cksum "$BUS9473" 2>/dev/null)"
expect_eq "$b9473_before" "$b9473_after" "T17 server.9473.pid unchanged"
if ss -tlnH 2>/dev/null | grep -qE "[:.]$TEAM_PORT[[:space:]]"; then
  fail "T17 no listener on team port $TEAM_PORT"
else
  pass "T17 no bus server on team port $TEAM_PORT (stub starts none)"
fi
[ -f "$HOME/.claude/data/inter-session/server.$TEAM_PORT.pid" ] && fail "T17 no bus pidfile for team port" || pass "T17 no bus pidfile for team port"

echo; echo "--- T18: digit-only role name rejected (would strip to empty base -> roles/.md)"
out="$(add "$GOAL" 123)"; rc=$?
expect_ne_rc 0 "$rc" "T18 rc nonzero"
expect_contains "$out" "non-digit" "T18 explains empty base"
[ -f "$repo/roles/.md" ] && { fail "T18 no junk roles/.md created"; rm -f "$repo/roles/.md"; } || pass "T18 no junk roles/.md created"

echo; echo "--- T19: --force re-files a unit whose id contains spaces (work not dropped)"
out="$(add "$GOAL" etlworker --reason 'etl gap')"; rc=$?
expect_rc 0 "$rc" "T19 add etlworker rc=0" "$out"
sleep 1
cat >> "$TEAM_DIR/state.md" <<'EOF'

## unit: etl gap
owner: etlworker
status: in-progress
notes: mid
EOF
out="$(retire etlworker --force --no-graceful --reason 'done')"; rc=$?
expect_rc 0 "$rc" "T19 force retire rc=0" "$out"
expect_contains "$out" "re-filed unit 'etl gap'" "T19 multi-word unit re-filed"
role_is_live etlworker && fail "T19 etlworker gone" || pass "T19 etlworker gone"
awk '/## unit: etl gap/{f=1} f&&/^status:/{print;exit}' "$TEAM_DIR/state.md" | grep -q 'todo' && pass "T19 unit status->todo" || fail "T19 unit status->todo"
awk '/## unit: etl gap/{f=1} f&&/^owner:/{print;exit}' "$TEAM_DIR/state.md" | grep -q 'owner: -' && pass "T19 unit owner cleared" || fail "T19 unit owner cleared"

echo; echo "--- T20: add-role (re)starts the api-watchdog if it is not running"
oldwd="$(cat "$TEAM_DIR/api-watchdog.pid" 2>/dev/null)"
[ -n "$oldwd" ] && kill -KILL "$oldwd" 2>/dev/null; sleep 1
expect_dead "$oldwd" "T20 watchdog killed"
out="$(add "$GOAL" wdcanary --reason 'watchdog probe')"; rc=$?
expect_rc 0 "$rc" "T20 add rc=0" "$out"
sleep 1
newwd="$(cat "$TEAM_DIR/api-watchdog.pid" 2>/dev/null)"
[ -n "$newwd" ] && [ "$newwd" != "$oldwd" ] && expect_alive "$newwd" "T20 a fresh watchdog is running" || fail "T20 watchdog restarted (old=$oldwd new=$newwd)"

echo; echo "--- T21: roster liveness ignores a recycled (non-claude) pid (unit, isolated dir)"
(
  d="$(mktemp -d)"; TEAM_DIR="$d"
  sleep 60 & s=$!
  printf '%s\t@9\tghost' "$s" > "$d/active"   # live but NOT claude, and no trailing newline
  c="$(live_role_count)"; rl=$(role_is_live ghost && echo live || echo dead)
  kill "$s" 2>/dev/null; rm -rf "$d"
  [ "$c" = 0 ] && [ "$rl" = dead ]
) && pass "T21 non-claude pid not counted live" || fail "T21 non-claude pid not counted live"

echo; echo "--- T22/T23: cross-team isolation (a retire in team A must never touch team B)"
RIDB="b9testB"
bport=$(printf '%s\0%s' "$repo" "$RIDB" | cksum | cut -d' ' -f1); bport=$((9500 + bport % 400))
if [ "$bport" = "$TEAM_PORT" ]; then
  fail "T22 precondition: team B port ($bport) collides with team A ($TEAM_PORT); pick another RIDB"
else
  pass "T22 teams A/B have distinct bus ports ($TEAM_PORT vs $bport)"
  bdir="$repo/.team-$RIDB"
  # Launch team B like a separate run.sh: clear team A's inherited team-env vars so
  # team-env derives team B's own port/dir/session (not team A's exported ones).
  ( cd "$repo" && env -u INTER_SESSION_PORT -u TEAM_PORT -u TEAM_DIR -u TEAM_SESSION \
      TEAM_RUN_ID="$RIDB" TEAM_ROLE_CMD="$stub" API_WATCHDOG_DISABLED=1 \
      ./bin/launch-team.sh "$GOAL" implementerb ) >/dev/null 2>&1
  sleep 1
  bpid="$(awk -F'\t' '$3=="implementerb"{print $1}' "$bdir/active" 2>/dev/null | tail -1)"
  [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null && pass "T22 team B role launched (pid $bpid)" || fail "T22 team B role launched"

  # T22: a normal retire in team A leaves team B's process alive.
  out="$(add "$GOAL" aonly --reason 'team A probe')"; arc=$?; sleep 1
  expect_rc 0 "$arc" "T22 add aonly rc=0 (liveA=$(live_role_count))" "$out"
  out="$(retire aonly --no-graceful --reason 'A retire')"; rc=$?
  expect_rc 0 "$rc" "T22 retire in team A rc=0" "$out"
  kill -0 "$bpid" 2>/dev/null && pass "T22 team B role survives a normal retire in team A" || fail "T22 team B role KILLED by team A retire"

  # T23: recycled-PID collision. Inject team B's LIVE pid into team A's roster under
  # a role name, then retire it from team A. A's ownership guard keys on the bus
  # port in the pid's environment (B has a different port), so it must NOT kill B's
  # process; it just cleans its own stale record.
  printf '%s\t@99\tintruder\n' "$bpid" >> "$TEAM_DIR/active"
  out="$(retire intruder --no-graceful --reason 'recycled-pid probe')"; rc=$?
  expect_rc 0 "$rc" "T23 retire of foreign-pid entry rc=0 (cleans own record)" "$out"
  kill -0 "$bpid" 2>/dev/null && pass "T23 team B pid NOT killed by team A retire (ownership guard held)" || fail "T23 CROSS-TEAM LEAK: team A retire killed team B's pid"
  role_is_live intruder && fail "T23 intruder entry removed from team A active" || pass "T23 intruder entry removed from team A active"

  # Tear down team B (stop-team kills B's own session; sweep + rm as a safety net).
  ( cd "$repo" && TEAM_RUN_ID="$RIDB" ./bin/stop-team.sh --no-graceful ) >/dev/null 2>&1
  if [ -f "$bdir/active" ]; then while IFS=$'\t' read -r p w r || [ -n "${p:-}" ]; do [ -n "${p:-}" ] && { kill -KILL "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; }; done < "$bdir/active"; fi
  rm -rf "$bdir"
fi

echo
echo "================ B9 suite: $P passed, $F failed ================"
if [ "$F" -gt 0 ]; then printf 'FAILED:\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
exit 0

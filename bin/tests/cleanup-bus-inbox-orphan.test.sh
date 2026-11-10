#!/usr/bin/env bash
# Test: bin/cleanup.sh step 3 finds an orphaned role that listens through bin/bus-inbox.py.
#
# Step 3 found an orphan by walking up from each /is client.py to a `claude` process. A bus-inbox client
# runs under the PUMP, which is started in its own session and re-parented to init, so the walk never
# reached the role's claude, and an orphaned role on bus-inbox was neither reaped nor reported. The pump's
# argv carries the claude pid it belongs to (`bus-inbox.py _pump <role> <claude pid>`), so cleanup reads it
# from there.
#
# Fixture, real processes with the real shapes, all detached (setsid --fork, re-parented to init):
#   - a fake role claude (a python3 started through a symlink named `claude`, so its comm is "claude"),
#     signed with ORCH_HOME=<sandbox repo>, in no tmux pane;
#   - a fake pump `python3 .../bus-inbox.py _pump <role> <claude pid>` whose child is a fake
#     `python3 .../skills/is/bin/client.py --name <role>`.
#   - an npm-installed twin: argv[0] `node`, its script in .../@anthropic-ai/claude-code/ (comm is not
#     "claude"), signed; step 3 used to look for comm "claude" only and missed it.
# Positive control both ways: the dry run must PLAN the reap, --force must kill the fake claude and the
# pump, and an UNSIGNED twin (no ORCH_HOME of the sandbox) must be reported and left running. An
# OTHER-RUN twin (this clone's ORCH_HOME, another TEAM_RUN_ID: a live team of another run) must also be
# reported and left running: "signed" is this clone AND this run, as step 2 gates daemons on the run.
#
# ISOLATION as in pidfile-stop-cleanup.test.sh: cleanup.sh runs from a COPY of bin/ in a sandbox repo, HOME
# is sandboxed, TEAM_TMUX is a throwaway socket. Step 3 scans the whole machine, but only processes whose
# claude has ORCH_HOME=<sandbox repo> are reaped; every live session has another ORCH_HOME (or none).
# SRC=<engine tree> runs the scripts of another tree (for the red run against the old code).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
alive(){ [ -d "/proc/$1" ] && ! /usr/bin/grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

SB="$(mktemp -d /tmp/cbio-XXXXXX)"
RID="cbio-$$"; R="$SB/repo"; SOCK="tcbio$$"
export NOTIFY_SINK="$SB/notify.sink" WATCH_ALERT_SINK="$SB/watch.sink"
PIDS="$SB/pids"; : > "$PIDS"
cleanup(){ local k; while read -r k; do [ -n "$k" ] && kill -9 "$k" 2>/dev/null; done < "$PIDS"
           tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf -- "${SB:?}"; }
trap cleanup EXIT
mkdir -p "$R" "$SB/home/.claude/data/inter-session" "$SB/fk/skills/is/bin"
cp -a "$SRC/bin" "$R/bin"
case "$R" in "$repo"|"$SRC"|/home/*/projects/*) echo "FATAL: sandbox repo is not a sandbox: $R" >&2; exit 99 ;; esac

# the REAL interpreter, not the first python3 on PATH: with a python3 shim earlier on PATH (pyenv, a test harness),
# a symlink to the shim script makes the kernel's comm the shim's interpreter, not "claude"
ln -s "$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')" "$SB/fk/claude"
# fake client: sleeps; fake pump: starts the client as its child, then sleeps; each writes its pid
printf 'import os, sys, time\nopen(sys.argv[-1], "w").write(str(os.getpid()))\ntime.sleep(600)\n' > "$SB/fk/skills/is/bin/client.py"
cat > "$SB/fk/bus-inbox.py" <<'PY'
import os, subprocess, sys, time
# argv: _pump <role> <cc pid> <pidfile prefix>
role, pre = sys.argv[2], sys.argv[4]
open(pre + ".pump", "w").write(str(os.getpid()))
subprocess.Popen([sys.executable, os.environ["FAKE_CLIENT"], "--name", role, pre + ".client"])
time.sleep(600)
PY
# the npm-installed shape: the same python code as a script inside the claude-code package, run as `node`
NPMJS="$SB/fk/pkg/node_modules/@anthropic-ai/claude-code/cli.js"; mkdir -p "${NPMJS%/*}"
printf 'import os, sys, time\nopen(sys.argv[1], "w").write(str(os.getpid()))\ntime.sleep(600)\n' > "$NPMJS"
waitfile(){ local i; for i in $(seq 1 50); do [ -s "$1" ] && { cat "$1"; return 0; }; sleep 0.1; done; return 1; }

# mk_role <role> <ORCH_HOME value or "-"> <TEAM_RUN_ID value> [npm] -> sets CL PUMP CLI
mk_role(){ local role="$1" oh="$2" run="$3" pre="$SB/$1"
  if [ "${4:-}" = npm ]; then
    env ORCH_HOME="$oh" TEAM_RUN_ID="$run" setsid --fork bash -c 'exec -a node "$0" "$@"' "$(readlink "$SB/fk/claude")" "$NPMJS" "$pre.cl" >/dev/null 2>&1 < /dev/null
  elif [ "$oh" = - ]; then
    env -u ORCH_HOME TEAM_RUN_ID="$run" setsid --fork "$SB/fk/claude" -c 'import os,sys,time; open(sys.argv[1],"w").write(str(os.getpid())); time.sleep(600)' "$pre.cl" >/dev/null 2>&1 < /dev/null
  else
    env ORCH_HOME="$oh" TEAM_RUN_ID="$run" setsid --fork "$SB/fk/claude" -c 'import os,sys,time; open(sys.argv[1],"w").write(str(os.getpid())); time.sleep(600)' "$pre.cl" >/dev/null 2>&1 < /dev/null
  fi
  CL="$(waitfile "$pre.cl")" || { echo "FATAL: fake claude for $role did not start" >&2; exit 99; }; echo "$CL" >> "$PIDS"
  env FAKE_CLIENT="$SB/fk/skills/is/bin/client.py" setsid --fork python3 "$SB/fk/bus-inbox.py" _pump "$role" "$CL" "$pre" >/dev/null 2>&1 < /dev/null
  PUMP="$(waitfile "$pre.pump")" || { echo "FATAL: fake pump for $role did not start" >&2; exit 99; }; echo "$PUMP" >> "$PIDS"
  CLI="$(waitfile "$pre.client")" || { echo "FATAL: fake client for $role did not start" >&2; exit 99; }; echo "$CLI" >> "$PIDS"; }

run_cleanup(){ env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" \
               bash "$R/bin/cleanup.sh" "$@" 2>&1; }

ROLE="cbio-orphan-$$"; mk_role "$ROLE" "$R" "$RID"; S_CL=$CL S_PUMP=$PUMP S_CLI=$CLI
UROLE="cbio-other-$$"; mk_role "$UROLE" - "$RID"; U_CL=$CL U_PUMP=$PUMP U_CLI=$CLI
OROLE="cbio-otherrun-$$"; mk_role "$OROLE" "$R" "other-live-run"; O_CL=$CL O_PUMP=$PUMP O_CLI=$CLI
NROLE="cbio-npm-$$"; mk_role "$NROLE" "$R" "$RID" npm; N_CL=$CL N_PUMP=$PUMP

# preconditions: the real shape (comm, re-parented pump, client under the pump, no claude above it)
[ "$(ps -o comm= -p "$S_CL")" = claude ] && ok "fixture: fake claude's comm is 'claude'" || no "fixture comm" "$(ps -o comm= -p "$S_CL")"
# detached: the pump leads its own session and the role's claude is not above it. Its parent is init, or the
# nearest child subreaper (systemd --user, a container init, WSL's per-session /init), so the ppid is not checked.
ancestors(){ local p="$1" i; for i in $(seq 1 64); do p="$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2>/dev/null)"
             case "$p" in ''|0) return ;; esac; echo "$p"; done; }
[ "$(ps -o sid= -p "$S_PUMP" | tr -d ' ')" = "$S_PUMP" ] && ! /usr/bin/grep -qxF "$S_CL" <<<"$(ancestors "$S_PUMP")" \
  && ok "fixture: the pump is detached (own session, the role's claude is not above it)" \
  || no "fixture pump detached" "sid $(ps -o sid= -p "$S_PUMP" | tr -d ' '), ancestors: $(ancestors "$S_PUMP" | tr '\n' ' ')"
[ "$(ps -o ppid= -p "$S_CLI" | tr -d ' ')" = "$S_PUMP" ] && ok "fixture: the client is the pump's child" || no "fixture client ppid" ""
/usr/bin/grep -qxF "ORCH_HOME=$R" <(tr '\0' '\n' < "/proc/$S_CL/environ") && ok "fixture: the role claude is signed with the sandbox ORCH_HOME" || no "fixture signature" ""
[ "$(ps -o comm= -p "$N_CL")" != claude ] && [ "$(tr '\0' '\n' < "/proc/$N_CL/cmdline" | head -2 | tr '\n' ' ')" = "node $NPMJS " ] \
  && ok "fixture: the npm twin runs as 'node .../@anthropic-ai/claude-code/cli.js', comm not 'claude'" || no "fixture npm shape" "$(tr '\0' ' ' < "/proc/$N_CL/cmdline")"

echo "== dry run"
out="$(run_cleanup)"
printf '%s\n' "$out" | /usr/bin/grep -E "$ROLE|$UROLE|$OROLE|$NROLE" | sed 's/^/     | /'
/usr/bin/grep -qF "[would] reap orphaned role '$NROLE' (this clone; claude pid $N_CL" <<<"$out" \
  && ok "dry run plans the reap of the npm-installed orphan (claude pid $N_CL)" || no "dry run did not find the npm-installed orphan" ""
/usr/bin/grep -qF "[would] reap orphaned role '$ROLE' (this clone; claude pid $S_CL" <<<"$out" \
  && ok "dry run plans the reap of the bus-inbox orphan (claude pid $S_CL)" || no "dry run did not find the bus-inbox orphan" ""
/usr/bin/grep -qE "pid $U_CL +role '$UROLE' +\(LEFT RUNNING\)" <<<"$out" \
  && ok "the unsigned twin is reported, LEFT RUNNING" || no "unsigned twin not reported" ""
/usr/bin/grep -qE "pid $O_CL +role '$OROLE' +run 'other-live-run' +\(LEFT RUNNING\)" <<<"$out" \
  && ok "the other-run twin (this clone, another TEAM_RUN_ID) is reported, LEFT RUNNING" || no "other-run twin not reported as another run's" ""
/usr/bin/grep -qF "reap orphaned role '$OROLE'" <<<"$out" && no "the reap of another run's role is planned" "" || ok "no reap planned for the other-run twin"
alive "$S_CL" && alive "$S_PUMP" && ok "dry run signalled nothing" || no "dry run killed something" ""

echo "== --force"
out="$(run_cleanup --force)"; sleep 1
alive "$S_CL" && no "the orphan's claude is still alive after --force" "" || ok "the orphan's claude was killed"
alive "$S_PUMP" && no "the orphan's pump is still alive after --force" "" || ok "the orphan's pump was killed"
alive "$N_CL" || alive "$N_PUMP" && no "the npm-installed orphan's claude or pump is still alive after --force" "" || ok "the npm-installed orphan's claude and pump were killed"
alive "$U_CL" && alive "$U_PUMP" && alive "$U_CLI" && ok "the unsigned twin's claude, pump and client are untouched" || no "the unsigned twin was touched" ""
alive "$O_CL" && alive "$O_PUMP" && alive "$O_CLI" && ok "the other-run twin's claude, pump and client survive --force" || no "the other-run twin was reaped" ""

[ ! -s "$NOTIFY_SINK" ] && [ ! -s "$WATCH_ALERT_SINK" ] && ok "nothing paged" || no "a sink was written" ""
echo "cleanup-bus-inbox-orphan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

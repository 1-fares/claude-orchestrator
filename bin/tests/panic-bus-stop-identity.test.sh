#!/usr/bin/env bash
# Test: panic.sh, stop-team.sh and cleanup.sh signal only this run's processes (bus server, roles,
# exited-role groups), and panic still stops everything when the identity check cannot run.
#   U   pid-identity units: a pidfile "1 2" is pid 1, not 12; `bash -o pipefail <script>` puts the
#       script, not `pipefail`, in program position; the bus-server gate takes --port N and
#       --port=N and refuses another port or another run.
#   P   panic.sh signals a pid read from a file only if it is THIS run's process: the bus server
#       (it used to be kill -0 + "args contain server.py"), the roles in active (it used to be "args
#       contain claude", for a GROUP kill), the daemons. Positive controls: this run's session, bus
#       server, role and daemon ARE stopped.
#   PF  panic.sh with bin/lib/pid-identity.sh BROKEN (a syntax error): it used to `exit 1` before
#       killing anything. Now it warns and falls back to the args match, and still stops this run's
#       session, bus server, role and daemon.
#   S   stop-team.sh pass 2: a role whose claude already exited leaves members in its process group.
#       The group is SIGKILLed when every live member is this run's, left (with one line) when not.
# The spawn side, same identity rules (roles are a stand-in `claude` script, every daemon disabled):
#   L   launch-team.sh: takes the roster lock (a line written under it by another holder is reaped
#       after it, not lost), keeps a started tmux server off that lock, does not spawn a live role
#       twice, reaps a live non-claude whose args contain "claude", keeps a live pane pid that is
#       not yet claude (the launching shell before its exec) when its window is in this session,
#       refuses `reviewer-`, names
#       the launcher that starts a missing curated role, and carries on to the communicator and the
#       curated-role check when the is-skill's list.py exits 1 ("not connected").
#   A   add-role.sh / retire-role.sh: a blank --reason and `delta-` are refused; a non-claude line in
#       active does not count toward the cap; add and retire are `info` notices (digest, no curl);
#       retire does not signal a leader pid now held by one of this run's daemons; a name whose
#       window exists without a live line in active is refused, and --auto-number skips it.
#   CM  communicator.sh: a failed tmux call exits 1 and records nothing; the prompt no longer names
#       inbound.jsonl; with CLAUDE_BIN unset it starts TEAM_ROLE_CMD.
#   SO  start-orchestrator.sh honours CLAUDE_BIN with no claude on PATH.
#   TS  team-status.sh: ALIVE is this run's claude by identity, not "claude" in the args line.
#   D   team-spawn opens daemon logs in append mode: an old log is kept, and a log truncated by the
#       rotation is not regrown with NUL bytes.   M  model_for never prints an empty model.
#
# ISOLATION as in pidfile-stop-cleanup.test.sh: the scripts run from a COPY of bin/ in a sandbox
# repo, HOME is sandboxed (bus pidfile dir), TEAM_TMUX is a throwaway socket, stop-team runs
# --no-graceful, NOTIFY_SINK/WATCH_ALERT_SINK are scratch files, and every process the test starts is
# setsid'd into its own group. SRC=<engine tree> runs another tree's scripts (the red run).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/tmux-socket.sh"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
alive(){ [ -d "/proc/$1" ] && ! /usr/bin/grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
show(){ printf '%s\n' "$1" | sed 's/^/     | /'; }

SB="$(mktemp -d /tmp/panicbus-XXXXXX)"
RID="panicbus-$$"
R="$SB/repo"
TD="$R/.team-$RID"
SOCK="tpb$$"
export NOTIFY_SINK="$SB/notify.sink" WATCH_ALERT_SINK="$SB/watch.sink"
KIDS="$SB/kids"
cleanup(){ local k; while read -r k; do pkill -9 -P "$k" 2>/dev/null; kill -9 "-$k" 2>/dev/null; kill -9 "$k" 2>/dev/null || true; done < "$KIDS"
           tmux_kill_unlink tmux "$SOCK"; rm -rf -- "${SB:?}"; }
trap cleanup EXIT
mkdir -p "$R" "$SB/d/bin" "$SB/home/.claude/data/inter-session"; : > "$KIDS"
cp -a "$SRC/bin" "$R/bin"
[ -f "$SRC/CLAUDE.md" ] && cp "$SRC/CLAUDE.md" "$R/"
case "$R" in "$SB"/*) ;; *) echo "FATAL: sandbox repo is not under the sandbox: $R" >&2; exit 99 ;; esac
for n in tmux-watchdog chrome-supervisor pipe-daemon; do
  printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$SB/d/bin/$n.sh"
done
printf 'import sys, time\nwhile True: time.sleep(1)\n' > "$SB/d/bin/server.py"
# The api-watchdog's shape: a TERM trap that waits for a FOREGROUND sleep, which inherits the flock fd.
# A SIGKILL of the parent alone (panic before 2026-11-10) orphans that sleep with the lock for 30 s.
printf '#!/usr/bin/env bash\ntrap "exit 0" TERM\nwhile true; do sleep 30; done\n' > "$SB/d/bin/api-watchdog.sh"
# A server.py that really LISTENS (panic's socket-ownership gate), on $LISTEN_PORT; no --port needed.
mkdir -p "$SB/d/lbin"
printf 'import os, socket, time\ns = socket.socket()\ns.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\ns.bind(("127.0.0.1", int(os.environ["LISTEN_PORT"])))\ns.listen(1)\nwhile True: time.sleep(1)\n' > "$SB/d/lbin/server.py"
chmod +x "$SB"/d/bin/*.sh

read -r PORT SESS < <( export TEAM_RUN_ID="$RID"; unset TEAM_DIR TEAM_PORT INTER_SESSION_PORT TEAM_SESSION; repo="$R"
                       . "$R/bin/team-env.sh" >/dev/null 2>&1; echo "$TEAM_PORT $TEAM_SESSION" )
[ -n "$PORT" ] && [ -n "$SESS" ] || { echo "FATAL: could not derive the sandbox run's TEAM_PORT/TEAM_SESSION" >&2; exit 99; }
BUSPF="$SB/home/.claude/data/inter-session/server.$PORT.pid"

# start <run-id|-> <argv...>: setsid'd background process; "-" = no run identity in its environ.
start(){ local r="$1"; shift
  if [ "$r" = - ]; then
    env -u TEAM_RUN_ID -u TEAM_DIR setsid ${EXEC_A:+bash -c 'exec -a "$0" "$@"' "$EXEC_A"} "$@" >/dev/null 2>"${FX_ERR:-/dev/null}" &
  else
    env TEAM_RUN_ID="$r" TEAM_DIR="$R/.team-$r" setsid ${EXEC_A:+bash -c 'exec -a "$0" "$@"' "$EXEC_A"} "$@" >/dev/null 2>"${FX_ERR:-/dev/null}" &
  fi
  local p=$!; echo "$p" >> "$KIDS"; echo "$p"; }
# orphans <pgid>: live members of the group that are neither its leader nor the leader's children
# (the TERM-ignoring orphans the fixtures leave behind; the leader's own foreground sleep dies on TERM).
orphans(){ ps -eo pid=,pgid=,ppid=,stat= | awk -v g="$1" '$2==g && $1!=g && $3!=g && $4 !~ /^Z/ {print $1}'; }
run_as_run(){ env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION -u ORCH_HOME TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" "$@" 2>&1; }
reset_procs(){ local k; while read -r k; do pkill -9 -P "$k" 2>/dev/null; kill -9 "-$k" 2>/dev/null; kill -9 "$k" 2>/dev/null || true; done < "$KIDS"
               : > "$KIDS"; tmux -L "$SOCK" kill-server 2>/dev/null; sleep 0.3; }
# settled <pid>...: wait (up to 5 s) until each started process runs its final program, not yet env,
# setsid or the exec -a wrapper. An identity row read before that would judge the wrapper.
settled(){ local p n c s; for n in 1 2 3 4 5 6 7 8 9 10; do c=0
  for p in "$@"; do s="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    case "$s" in ''|env\ *|*/env\ *|setsid\ *|*/setsid\ *|*'exec -a "$0" "$@"'*) c=1 ;; esac; done
  [ "$c" = 0 ] && return 0; sleep 0.5; done; return 1; }

echo "=== U: pid-identity units ($SRC) ==="
u(){ env TEAM_RUN_ID="$RID" TEAM_DIR="$TD" bash -c '. "$1/bin/lib/pid-identity.sh"; shift; "$@"' _ "$R" "$@"; }
# ue <code> <args>: eval <code> with the library loaded and <args> as $1.. (a nested `bash -c` would
# not have the sourced functions).
ue(){ local code="$1"; shift
  env TEAM_RUN_ID="$RID" TEAM_DIR="$TD" bash -c '. "$1/bin/lib/pid-identity.sh"; c="$2"; shift 2; eval "$c"' _ "$R" "$code" "$@"; }
mkdir -p "$TD"
SELFPID="$(start "$RID" bash "$SB/d/bin/tmux-watchdog.sh")"; sleep 0.3
printf '%s 2\n' "$SELFPID" > "$SB/twofield.pid"
r="$(ue 'proc_pidfile_verdict "$1" bin/tmux-watchdog.sh; echo "rc=$? pid=$PM_PID why=$PM_WHY"' "$SB/twofield.pid")"
case "$r" in "rc=0 pid=$SELFPID "*) ok "pidfile: pidfile '<pid> 2' reads the FIRST field (pid $SELFPID), verdict ours" ;;
             *) no "pidfile: pidfile '<pid> 2' must read the first field" "$r" ;; esac
printf '1 2\n' > "$SB/onetwo.pid"
r="$(ue 'proc_pidfile_verdict "$1" bin/tmux-watchdog.sh; echo "rc=$? pid=$PM_PID"' "$SB/onetwo.pid")"
case "$r" in "rc=1 pid=1") ok "pidfile: pidfile '1 2' is pid 1 (refused: init is not this run's), not pid 12" ;; *) no "pidfile: '1 2' -> pid 1" "$r" ;; esac
printf '  %s \r\n' "$SELFPID" > "$SB/crlf.pid"
r="$(ue 'proc_pidfile_verdict "$1" bin/tmux-watchdog.sh; echo "rc=$? pid=$PM_PID"' "$SB/crlf.pid")"
[ "$r" = "rc=0 pid=$SELFPID" ] && ok "pidfile control: blanks and a CRLF around one pid still read as that pid" || no "pidfile crlf control" "$r"
PIPED="$(start "$RID" bash -o pipefail "$SB/d/bin/pipe-daemon.sh")"
PIPED_OTHER="$(start "other-$$" bash -o pipefail "$SB/d/bin/pipe-daemon.sh")"; sleep 0.3
u proc_pid_is_run_daemon "$PIPED" bin/pipe-daemon.sh && ok "interpreter option: 'bash -o pipefail <script>' of this run matches its script" || no "interpreter option: -o operand skipped" ""
u proc_pid_is_run_daemon "$PIPED_OTHER" bin/pipe-daemon.sh && no "interpreter option control: another run's 'bash -o pipefail' daemon refused" "" || ok "interpreter option control: another run's 'bash -o pipefail' daemon still refused"
u proc_pid_is_run_daemon "$PIPED" pipefail && no "interpreter option: 'pipefail' is no longer the program" "" || ok "interpreter option: 'pipefail' is no longer taken as the program"
for form in "-eo pipefail" "--rcfile /dev/null" "-o pipefail -x"; do
  P2="$(start "$RID" bash $form "$SB/d/bin/pipe-daemon.sh")"; sleep 0.3
  u proc_pid_is_run_daemon "$P2" bin/pipe-daemon.sh && ok "interpreter option: 'bash $form <script>' matches its script" || no "interpreter option: bash $form" ""
done
printf 'import time\nwhile True: time.sleep(1)\n' > "$SB/d/bin/py-daemon.py"
P3="$(start "$RID" python3 -uW ignore "$SB/d/bin/py-daemon.py")"; sleep 0.3
u proc_pid_is_run_daemon "$P3" bin/py-daemon.py && ok "interpreter option: 'python3 -uW ignore <script>' matches its script" || no "interpreter option: python3 -uW ignore" ""
SRV_EQ="$(start "$RID" python3 "$SB/d/bin/server.py" --fd 8 --port="$PORT")"
SRV_SP="$(start "$RID" python3 "$SB/d/bin/server.py" --host 127.0.0.1 --port "$PORT")"
SRV_P1="$(start "$RID" python3 "$SB/d/bin/server.py" --port 1)"
SRV_FX="$(start "other-$$" python3 "$SB/d/bin/server.py" --port "$PORT")"; sleep 0.4
u proc_pid_is_run_bus_server "$SRV_EQ" "$PORT" && ok "--port= form: bus gate accepts --port=$PORT (equals form)" || no "--port= form: --port= form" ""
u proc_pid_is_run_bus_server "$SRV_SP" "$PORT" && ok "bus gate accepts --port $PORT" || no "bus gate --port N" ""
u proc_pid_is_run_bus_server "$SRV_P1" "$PORT" && no "bus gate refuses another port" "" || ok "bus gate refuses this run's server on ANOTHER port"
u proc_pid_is_run_bus_server "$SRV_FX" "$PORT" && no "bus gate refuses another run" "" || ok "bus gate refuses ANOTHER run's server on this port"
# A claude is judged by what it executes: a script named claude, an npm install (argv[0] node, its
# script in the @anthropic-ai/claude-code package), a native install exec'd by its claude/versions/
# path. Never a process whose args merely contain the word or the package path.
NPMCLI="$SB/d/pkg/node_modules/@anthropic-ai/claude-code/cli.js"
mkdir -p "$SB/d/cl" "${NPMCLI%/*}"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$SB/d/cl/claude"; chmod +x "$SB/d/cl/claude"
cp "$SB/d/cl/claude" "$NPMCLI"
CL_SCRIPT="$(start "$RID" "$SB/d/cl/claude")"
CL_BARE="$(start - "$SB/d/cl/claude")"
CL_NODE="$(EXEC_A=node start "$RID" bash "$NPMCLI")"
CL_NODE_BARE="$(EXEC_A=node start - bash "$NPMCLI")"
CL_VER="$(EXEC_A="$SB/d/share/claude/versions/9.9.9" start "$RID" bash -c 'while :; do sleep 1; done')"
CL_WORD="$(start "$RID" bash -c 'sleep 600; :' claude)"
CL_PKGWORD="$(start "$RID" bash -c 'sleep 600; :' "$NPMCLI")"
settled "$CL_SCRIPT" "$CL_BARE" "$CL_NODE" "$CL_NODE_BARE" "$CL_VER" "$CL_WORD" "$CL_PKGWORD" \
  && ok "claude identity precondition: every stand-in runs its final program" || no "claude identity precondition: a stand-in did not settle within 5 s" ""
u proc_pid_is_run_claude "$CL_SCRIPT" && ok "claude identity: a script named claude, this run's" || no "claude identity: script named claude" ""
u proc_pid_is_run_claude "$CL_NODE" && ok "claude identity: node running .../@anthropic-ai/claude-code/cli.js (npm install), this run's" || no "claude identity: npm install" ""
u proc_pid_is_run_claude "$CL_VER" && ok "claude identity: argv[0] under claude/versions/ (native install by its real path), this run's" || no "claude identity: versions path" ""
u proc_pid_is_run_claude "$CL_BARE" && no "claude identity: a claude without this run's environ is refused" "" || ok "claude identity: a claude without this run's environ is not this run's"
u proc_pid_is_run_claude "$CL_WORD" && no "claude identity: args containing the word claude are refused" "" || ok "claude identity: a shell whose args contain the word claude is not a claude"
u proc_pid_is_claude_shape "$CL_WORD" && no "claude shape: args word refused" "" || ok "claude shape: a shell whose args contain the word claude is not a claude, in any run"
u proc_pid_is_claude_shape "$CL_PKGWORD" && no "claude shape: package path outside node refused" "" || ok "claude shape: the package path as an argument of a non-node program is not a claude"
tdg(){ env -u TEAM_RUN_ID -u TEAM_DIR bash -c '. "$1/bin/lib/team-dir-guard.sh"; _tdg_pid_is_claude "$2"' _ "$R" "$1"; }
tdg "$CL_NODE_BARE" && ok "team-dir guard: an npm-installed claude with no run environ is a claude (other runs' dirs)" || no "team-dir guard: npm claude" ""
tdg "$CL_SCRIPT" && ok "team-dir guard: a script named claude is a claude" || no "team-dir guard: script named claude" ""
tdg "$CL_WORD" && no "team-dir guard: args word refused" "" || ok "team-dir guard: a shell whose args contain the word claude is not a claude"
reset_procs

# Panic scenario. Sets globals for the asserts.
panic_scenario(){
  mkdir -p "$TD"
  env TEAM_RUN_ID="$RID" TEAM_DIR="$TD" tmux -L "$SOCK" new-session -d -s "$SESS" "sleep 600"
  [ -S "$(tmux_sock_path "$SOCK")" ] && SOCK_SEEN=1
  PANE="$(tmux -L "$SOCK" list-panes -s -t "$SESS" -F '#{pane_pid}' 2>/dev/null | head -1)"
  ROLE="$(EXEC_A=claude start "$RID" sleep 600)"                     # this run's role, detached
  NPMROLE="$(EXEC_A=node start "$RID" bash "$NPMCLI")"               # this run's role, npm install
  ROLE_OTHER="$(EXEC_A=claude start "other-$$" sleep 600)"          # another run's claude
  SHELLC="$(start "$RID" bash -c 'sleep 600; :' claude)"             # args contain "claude"
  BARE="$(start - sleep 600)"                                        # no run env (sshd-like)
  TWD="$(start "$RID" bash "$SB/d/bin/tmux-watchdog.sh")"            # this run's daemon
  AWD="$(start "$RID" bash "$SB/d/bin/api-watchdog.sh")"             # this run's daemon, foreground sleep
  FOREIGN="$(start "other-$$" bash "$SB/d/bin/chrome-supervisor.sh")" # another run's daemon
  SRV="$(start "$RID" python3 "$SB/d/bin/server.py" --fd 8 --host 127.0.0.1 --port "$PORT")"
  SRV_FX="$(start "other-$$" python3 "$SB/d/bin/server.py" --port "$PORT")"
  sleep 0.6; settled "$ROLE" "$NPMROLE" "$ROLE_OTHER"
  AWD_KID="$(pgrep -P "$AWD" 2>/dev/null | head -1)"; [ -n "$AWD_KID" ] && echo "$AWD_KID" >> "$KIDS"
  printf '%s\t-\tbuilder\n%s\t-\tnpmrole\n%s\t-\tother\n%s\t-\tshellc\n' "$ROLE" "$NPMROLE" "$ROLE_OTHER" "$SHELLC" > "$TD/active"
  echo "$TWD"     > "$TD/tmux-watchdog.pid"
  echo "$AWD"     > "$TD/api-watchdog.pid"
  echo "$FOREIGN" > "$TD/chrome-supervisor.pid"
  echo "$BARE"    > "$TD/observer.pid"
}
panic_pre(){ local p bad=""
  for p in $PANE $ROLE $NPMROLE $ROLE_OTHER $SHELLC $BARE $TWD $AWD $FOREIGN $SRV $SRV_FX; do alive "$p" || bad="$bad $p"; done
  [ -n "$PANE" ] || bad="$bad no-pane"
  [ -n "$AWD_KID" ] && alive "$AWD_KID" || bad="$bad awd-child"
  [ -z "$bad" ] && ok "$1 preconditions: session pane and all fixtures alive" || no "$1 preconditions" "dead:$bad"; }
run_panic(){ run_as_run bash "$R/bin/panic.sh"; }

echo "=== P: panic.sh, identity check available ($SRC) ==="
panic_scenario; panic_pre P
echo "$SRV_FX" > "$BUSPF"                    # the bus pidfile names ANOTHER run's server.py on this port
out="$(run_panic)"; sleep 0.6; show "$out"
alive "$SRV_FX" && ok "P: bus pidfile -> another run's server.py on this port SURVIVES" || no "P: foreign bus server survives (was: args contain server.py)" ""
[ -f "$BUSPF" ] && ok "P: refused bus pidfile left in place (shared bus state)" || no "P: refused bus pidfile left" ""
alive "$ROLE_OTHER" && ok "P: active -> another run's claude SURVIVES (no group kill)" || no "P: other run's claude survives (was: args contain claude)" ""
alive "$SHELLC" && ok "P: active -> a shell whose args contain 'claude' SURVIVES" || no "P: args-claude shell survives" ""
alive "$FOREIGN" && ok "P: chrome-supervisor.pid -> another run's daemon SURVIVES" || no "P: foreign daemon survives" ""
alive "$BARE" && ok "P: observer.pid -> process with no run env SURVIVES" || no "P: bare survives" ""
alive "$PANE" && no "P: POSITIVE session pane killed" "" || ok "P: POSITIVE this run's tmux session pane KILLED"
alive "$ROLE" && no "P: POSITIVE role killed" "" || ok "P: POSITIVE this run's role claude (from active) KILLED"
alive "$NPMROLE" && no "P: POSITIVE npm-installed role killed" "" || ok "P: POSITIVE this run's npm-installed role (node .../@anthropic-ai/claude-code/cli.js) KILLED"
alive "$TWD" && no "P: POSITIVE daemon killed" "" || ok "P: POSITIVE this run's tmux-watchdog KILLED"
alive "$AWD" && no "P: POSITIVE api-watchdog killed" "" || ok "P: POSITIVE this run's api-watchdog KILLED"
alive "$AWD_KID" && no "P: POSITIVE api-watchdog's foreground sleep (holds its flock fd) reaped" "" || ok "P: POSITIVE api-watchdog's foreground sleep child REAPED (pkill -P)"
/usr/bin/grep -q "skip /is bus server: pid $SRV_FX" <<<"$out" && ok "P: one skip line names the refused bus pid" || no "P: bus skip line" ""
/usr/bin/grep -q "skip other: pid $ROLE_OTHER" <<<"$out" && ok "P: one skip line names the refused role pid" || no "P: role skip line" ""
/usr/bin/grep -q "WARNING identity check unavailable" <<<"$out" && no "P: no fallback warning when the check is available" "" || ok "P: no fallback warning when the identity check is available"
echo "$SRV" > "$BUSPF"
out="$(run_panic)"; sleep 0.6
alive "$SRV" && no "P: POSITIVE bus server stopped" "$out" || ok "P: POSITIVE this run's server.py on port $PORT STOPPED"
reset_procs

echo "=== PF: panic.sh with bin/lib/pid-identity.sh broken (identity check cannot run) ==="
cp "$R/bin/lib/pid-identity.sh" "$SB/pid-identity.good"
printf '\nif then  # deliberately broken by panic-bus-stop-identity.test.sh\n' >> "$R/bin/lib/pid-identity.sh"
bash -n "$R/bin/lib/pid-identity.sh" 2>/dev/null && no "PF precondition: the library is broken" "" || ok "PF precondition: sandbox pid-identity.sh has a syntax error"
panic_scenario; panic_pre PF
# The fallback matches a WORD's basename, not a substring: argv0 `claude-helper` is not claude, and a
# `myserver.py` on this port is not server.py (the older substring match killed both).
CCFG="$(EXEC_A=claude-helper start - sleep 600)"
MYSRV="$(start - python3 "$SB/d/bin/myserver.py" --port "$PORT")"; cp "$SB/d/bin/server.py" "$SB/d/bin/myserver.py"; sleep 0.4
printf '%s\t-\tccfg\n' "$CCFG" >> "$TD/active"
echo "$MYSRV" > "$BUSPF"
out0="$(run_panic)"; sleep 0.6
alive "$CCFG" && ok "PF: argv0 'claude-helper' named in active SURVIVES the args fallback (word match)" || no "PF: claude-helper survives" "$out0"
alive "$MYSRV" && ok "PF: 'myserver.py --port $PORT' named by the bus pidfile SURVIVES the args fallback" || no "PF: myserver.py survives" "$out0"
reset_procs; panic_scenario
echo "$SRV" > "$BUSPF"
out="$(run_panic)"; rc=$?; sleep 0.6; show "$out"
/usr/bin/grep -q "WARNING identity check unavailable (bin/lib/pid-identity.sh did not load)" <<<"$out" \
  && ok "PF: says on stderr that the identity check is unavailable, and why" || no "PF: fallback warning" ""
alive "$PANE" && no "PF: POSITIVE session pane killed" "" || ok "PF: POSITIVE session pane KILLED (no identity check needed)"
alive "$ROLE" && no "PF: POSITIVE role killed" "" || ok "PF: POSITIVE this run's role KILLED (args fallback)"
alive "$TWD"  && no "PF: POSITIVE daemon killed" "" || ok "PF: POSITIVE this run's tmux-watchdog KILLED (args fallback)"
alive "$SRV"  && no "PF: POSITIVE bus server stopped" "" || ok "PF: POSITIVE this run's bus server STOPPED (args + port fallback)"
alive "$BARE" && ok "PF: a pidfile naming an unrelated program (sleep) SURVIVES even in the fallback" || no "PF: bare survives" ""
alive "$SRV_FX" && ok "PF: bus server of another run not named by the pidfile SURVIVES" || no "PF: unnamed foreign server survives" ""
# Stated, not hidden: the fallback IS the older args match. Another run's claude named in active
# matches "claude" and is killed -- the degraded mode trades that for a panic button that works.
alive "$ROLE_OTHER" && no "PF: (documented) the args fallback also kills another run's claude named in active" "" \
  || ok "PF: DOCUMENTED degraded behaviour: args fallback kills another run's claude named in active"
cp "$SB/pid-identity.good" "$R/bin/lib/pid-identity.sh"
reset_procs

echo "=== S: stop-team.sh pass 2, a role whose claude already exited ($SRC) ==="
mkdir -p "$TD"
# QUICK: exits on TERM, leaves an orphan in its group that ignores TERM (this run's env).
QUICK="$(EXEC_A=claude start "$RID" bash -c '( ( trap "" TERM; exec sleep 600 ) & ); sleep 600; :')"
# MIXED: same, plus a second orphan WITHOUT the run env: the group is not provably this run's.
MIXED="$(EXEC_A=claude start "$RID" bash -c '( ( trap "" TERM; exec sleep 600 ) & ); ( ( trap "" TERM; exec env -u TEAM_RUN_ID -u TEAM_DIR sleep 601 ) & ); sleep 600; :')"
# GONE: its claude died BEFORE stop-team ran (SIGKILLed here); its group still holds an orphan.
GONE="$(EXEC_A=claude start "$RID" bash -c '( ( trap "" TERM; exec sleep 600 ) & ); sleep 600; :')"
sleep 0.6
mapfile -t QO < <(orphans "$QUICK")
mapfile -t MO < <(orphans "$MIXED")
mapfile -t GO < <(orphans "$GONE")
kill -9 "$GONE"; sleep 0.3
[ "${#QO[@]}" -eq 1 ] && [ "${#MO[@]}" -eq 2 ] && [ "${#GO[@]}" -eq 1 ] && ! alive "$GONE" && alive "$QUICK" && alive "$MIXED" \
  && ok "S preconditions: orphans in each group (quick ${#QO[@]}, mixed ${#MO[@]}, gone ${#GO[@]}), GONE's claude already dead" \
  || no "S preconditions" "quick=${QO[*]} mixed=${MO[*]} gone=${GO[*]}"
printf '%s\t-\tquick\n%s\t-\tmixed\n%s\t-\tgone\n' "$QUICK" "$MIXED" "$GONE" > "$TD/active"
SRV_EQ="$(start "$RID" python3 "$SB/d/bin/server.py" --fd 8 --port="$PORT")"; sleep 0.3
echo "$SRV_EQ" > "$BUSPF"
out="$(run_as_run bash "$R/bin/stop-team.sh" --no-graceful)"; sleep 0.8; show "$out"
alive "$QUICK" && no "S: QUICK role stopped by TERM" "" || ok "S: TERM-exiting role stopped"
left=""; for p in "${QO[@]}"; do alive "$p" && left="$left $p"; done
[ -z "$left" ] && ok "S: POSITIVE orphan(s) left in the exited role's group KILLED (pass 2 group kill)" || no "S: exited role's orphans killed" "alive:$left"
left=""; for p in "${GO[@]}"; do alive "$p" && left="$left $p"; done
[ -z "$left" ] && ok "S: POSITIVE orphan in the group of a role that died BEFORE stop-team KILLED" || no "S: dead-before-stop role's orphan killed" "alive:$left"
left=0; for p in "${MO[@]}"; do alive "$p" && left=$((left+1)); done
[ "$left" -eq "${#MO[@]}" ] && ok "S: a group with a member WITHOUT this run's env is LEFT (both TERM-ignoring orphans alive)" || no "S: mixed group left" "$left of ${#MO[@]} alive"
/usr/bin/grep -q "skip group of exited mixed (pgid $MIXED): member(s)" <<<"$out" && ok "S: one skip line names the mixed group and its foreign member" || no "S: mixed skip line" ""
/usr/bin/grep -q "KILL group of exited gone (pgid $GONE" <<<"$out" && ok "S: one KILL line names the dead-before-stop role's group" || no "S: gone KILL line" ""
alive "$SRV_EQ" && no "S: POSITIVE bus server started with --port=$PORT stopped" "" || ok "S: POSITIVE bus server started with --port=$PORT STOPPED"
reset_procs

echo "=== S-self: stop-team.sh run from INSIDE an exited role's process group ==="
mkdir -p "$TD"; rm -f "$SB/selfout" "$SB/selfpid"
# The leader writes its pid (= the group id) to active and exits; a child left in the group runs
# stop-team a moment later. Without the own-group check the group kill would take stop-team itself.
start "$RID" bash -c 'printf "%s\t-\tselfrole\n" "$$" > "$1/active"; echo "$$" > "$2/selfpid"
  ( sleep 1; env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION TEAM_TMUX="$3" HOME="$2/home" \
      bash "$4/bin/stop-team.sh" --no-graceful > "$2/selfout" 2>&1; echo "rc=$?" >> "$2/selfout" ) &
  exit 0' _ "$TD" "$SB" "$SOCK" "$R" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do /usr/bin/grep -q '^rc=' "$SB/selfout" 2>/dev/null && break; sleep 0.5; done
show "$(cat "$SB/selfout" 2>/dev/null)"
/usr/bin/grep -q '^rc=' "$SB/selfout" 2>/dev/null && ok "S-self: stop-team ran to completion (it did not kill itself)" || no "S-self: stop-team completed" "$(cat "$SB/selfout" 2>/dev/null)"
/usr/bin/grep -q "skip group of exited selfrole (pgid $(cat "$SB/selfpid")): it is the process group of this stop-team or one of its ancestors" "$SB/selfout" 2>/dev/null \
  && ok "S-self: one line says the group is the caller's own and leaves it" || no "S-self: own-group skip line" ""
reset_procs

echo "=== S-anc: a caller INSIDE an exited role's group that setsid's stop-team ==="
mkdir -p "$TD"; rm -f "$SB/ancout" "$SB/ancpid" "$SB/ancalive"
# The leader exits; a member of its group (the "caller") setsid's stop-team, so stop-team's own pgid
# differs, and then waits for it. Killing the dead role's group would take the caller.
start "$RID" bash -c 'printf "%s\t-\tancrole\n" "$$" > "$1/active"; echo "$$" > "$2/ancpid"
  ( sleep 1; setsid env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION TEAM_TMUX="$3" HOME="$2/home" \
      bash "$4/bin/stop-team.sh" --no-graceful > "$2/ancout" 2>&1; echo "rc=$?" >> "$2/ancout"; sleep 1; echo caller-alive > "$2/ancalive" ) &
  exit 0' _ "$TD" "$SB" "$SOCK" "$R" >/dev/null
for _ in $(seq 1 24); do [ -f "$SB/ancalive" ] && break; sleep 0.5; done
show "$(cat "$SB/ancout" 2>/dev/null)"
[ -f "$SB/ancalive" ] && ok "S-anc: the calling member of the dead group SURVIVES stop-team" || no "S-anc: caller survives" "$(cat "$SB/ancout" 2>/dev/null)"
/usr/bin/grep -q "skip group of exited ancrole (pgid $(cat "$SB/ancpid" 2>/dev/null)): it is the process group of this stop-team or one of its ancestors" "$SB/ancout" 2>/dev/null \
  && ok "S-anc: one line says the group is an ancestor's and leaves it" || no "S-anc: ancestor skip line" ""
reset_procs

echo "=== PB: panic, a bus server on THIS run's port without the run env or without --port ==="
# Old panic: kill -0 + "args contain server.py" stopped these. Panic must not stop LESS: a server.py
# provably LISTENING on TEAM_PORT, named by server.<TEAM_PORT>.pid, is stopped without the env.
OPORT=$((PORT + 1)); _ltn="$(ss -ltn 2>/dev/null)"; while /usr/bin/grep -q ":$OPORT " <<<"$_ltn"; do OPORT=$((OPORT + 1)); done
listening(){ /usr/bin/grep -q "127\.0\.0\.1:$1 " <<<"$(ss -ltn 2>/dev/null)"; }
# Readiness, not fixed sleeps: under a loaded pre-push gate the previous case's server had not released the port
# within the old 0.3 s + 0.6 s, the new one's bind failed, and "fixture alive" failed (3 rows, 2026-11-03).
pb_case(){ # <label> <expect stopped|survives> <run-id|-> <listen-port> [args...]
  local label="$1" want="$2" r="$3" lp="$4" pid out i; shift 4
  mkdir -p "$TD"
  for i in $(seq 1 100); do listening "$lp" || break; sleep 0.1; done
  : > "$SB/fx.err"
  pid="$(FX_ERR="$SB/fx.err" LISTEN_PORT="$lp" start "$r" python3 "$SB/d/lbin/server.py" "$@")"
  for i in $(seq 1 100); do { alive "$pid" && listening "$lp"; } && break; alive "$pid" || break; sleep 0.1; done
  { alive "$pid" && listening "$lp"; } || { no "PB $label: fixture alive and listening on $lp" \
    "alive=$(alive "$pid" && echo yes || echo no) stderr: $(tail -c 300 "$SB/fx.err" 2>/dev/null) port: $(ss -ltn 2>/dev/null | /usr/bin/grep ":$lp ")"; reset_procs; return; }
  echo "$pid" > "$BUSPF"
  out="$(run_panic)"
  if [ "$want" = stopped ]; then for i in $(seq 1 50); do alive "$pid" || break; sleep 0.1; done; else sleep 0.6; fi
  if [ "$want" = stopped ]; then alive "$pid" && no "PB $label: STOPPED" "$out" || ok "PB $label: STOPPED"
  else alive "$pid" && ok "PB $label: SURVIVES" || no "PB $label: survives" "$out"; fi
  reset_procs
}
pb_case "no run env, --port $PORT, listening on $PORT" stopped - "$PORT" --port "$PORT"
pb_case "this run's env, NO --port argument, listening on $PORT" stopped "$RID" "$PORT"
pb_case "no run env, listening on ANOTHER port $OPORT" survives - "$OPORT" --port "$OPORT"
pb_case "no run env, --port $PORT in args but listening on $OPORT" survives - "$OPORT" --port "$PORT"
pb_case "this run's env, --port $PORT, listening (the live shape)" stopped "$RID" "$PORT" --fd 8 --host 127.0.0.1 --port "$PORT"

# Z: a ZOMBIE role root. Its parent never reaps it, so after TERM the root is a zombie: /proc/<pid>
# stays, the cmdline is empty, the identity check refuses it, and the old code skipped the group kill
# (stop-team pass 2 and cleanup's killtree_verified alike), leaving the TERM-ignoring orphan running.
# zombie_role <pidfile>: a python parent that forks a setsid'd "claude" (argv0) with such an orphan,
# writes the role pid, and never waits.
zombie_role(){ start "$RID" python3 -c '
import os, sys, time
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp("bash", ["claude", "-c", "( ( trap \"\" TERM; exec sleep 600 ) & ); sleep 600; :"])
open(sys.argv[1], "w").write(str(pid))
time.sleep(600)' "$1" >/dev/null; }
for tool in stop-team cleanup; do
  echo "=== Z: $tool.sh, a zombie role root ==="
  mkdir -p "$TD"; rm -f "$SB/zrole"
  zombie_role "$SB/zrole"; sleep 0.8
  ZR="$(cat "$SB/zrole" 2>/dev/null)"; echo "$ZR" >> "$KIDS"
  mapfile -t ZO < <(orphans "$ZR")
  [ -n "$ZR" ] && alive "$ZR" && [ "${#ZO[@]}" -eq 1 ] && ok "Z $tool preconditions: role $ZR alive, one orphan in its group" || no "Z $tool preconditions" "role=$ZR orphans=${ZO[*]}"
  printf '%s\t-\tzrole\n' "$ZR" > "$TD/active"
  if [ "$tool" = stop-team ]; then out="$(run_as_run bash "$R/bin/stop-team.sh" --no-graceful)"
  else out="$(run_as_run bash "$R/bin/cleanup.sh" --force)"; fi
  sleep 0.8; show "$out"
  /usr/bin/grep -q '^State:[[:space:]]*Z' "/proc/$ZR/status" 2>/dev/null && ok "Z $tool: the role root is a zombie (fixture holds)" || no "Z $tool: role root is a zombie" "$(head -3 "/proc/$ZR/status" 2>&1)"
  left=""; for p in "${ZO[@]}"; do alive "$p" && left="$left $p"; done
  [ -z "$left" ] && ok "Z $tool: POSITIVE orphan in a zombie root's group KILLED" || no "Z $tool: zombie root's orphan killed" "alive:$left"
  reset_procs
done

echo "=== L/A/CM/SO/D/M: the spawn side ($SRC) ==="
reset_procs
mkdir -p "$TD" "$R/roles" "$R/goals" "$R/templates" "$SB/stub" "$SB/fakebin" "$SB/faketmux"
: > "$TD/active"
cp "$SRC/roles/_TEMPLATE.md" "$SRC/roles/user-communicator.md" "$R/roles/"
cp "$SRC/templates/state.md" "$R/templates/"
echo "# goal" > "$R/goals/g.md"
STUB="$SB/stub/claude"     # the role stand-in: `claude` in program position, never exits
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$STUB"
printf '#!/bin/sh\necho "$*" >> "%s/curl.calls"\n' "$SB" > "$SB/fakebin/curl"
printf '#!/bin/sh\nexit 1\n' > "$SB/faketmux/tmux"
chmod +x "$STUB" "$SB/fakebin/curl" "$SB/faketmux/tmux"; : > "$SB/curl.calls"
NOCL_PATH=""; IFS=: read -ra _pp <<<"$PATH"
for d in "${_pp[@]}"; do [ -n "$d" ] && [ ! -e "$d/claude" ] && NOCL_PATH="${NOCL_PATH:+$NOCL_PATH:}$d"; done
spawn_env=(env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION -u ORCH_HOME -u CLAUDE_CONFIG_FILE -u MAX_TEAM_SIZE
  TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" TEAM_ROLE_CMD="$STUB" CLAUDE_BIN="$STUB"
  NTFY_URL="http://127.0.0.1:9/unused" PATH="$SB/fakebin:$PATH"
  API_WATCHDOG_DISABLED=1 COMPACT_WATCHDOG_DISABLED=1 TMUX_WATCHDOG_DISABLED=1 PERMISSION_MODE_WATCHDOG_DISABLED=1
  HOST_RAM_WATCHDOG_DISABLED=1 DISK_TMP_WATCHDOG_DISABLED=1 OBSERVER_DISABLED=1 CHROME_SUPERVISOR_DISABLED=1
  INTAKE_POLLER_DISABLED=1 COMMUNICATOR_DISABLED=1)
sp(){ "${spawn_env[@]}" "$@" </dev/null 2>&1; }
pid_of(){ awk -F'\t' -v r="$1" '$3==r {print $1}' "${2:-$TD/active}"; }
lines_of(){ awk -F'\t' -v r="$1" '$3==r' "${2:-$TD/active}" | wc -l | tr -d ' '; }
track(){ local p; for p in $(cut -f1 "${1:-$TD/active}" 2>/dev/null); do case "$p" in *[!0-9]*|'') ;; *) echo "$p" >> "$KIDS" ;; esac; done; }

out="$(sp bash "$R/bin/launch-team.sh" "$R/goals/g.md" alpha1 beta1)"; rc=$?; track; show "$out"
[ "$rc" = 0 ] && [ -n "$(pid_of alpha1)" ] && [ -n "$(pid_of beta1)" ] && ok "L: launch-team starts alpha1 and beta1 and records both" || no "L: cold launch" "rc=$rc"
ue 'proc_pid_is_run_claude "$1"' "$(pid_of alpha1)" && ok "L: a recorded role is this run's claude by identity (the stand-in)" || no "L: stand-in identity" ""
[ "$(cat "$TD/models/alpha1" 2>/dev/null)" = opus ] && ok "L: the role launched with an explicit model (opus)" || no "L: model recorded" "$(cat "$TD/models/alpha1" 2>&1)"
srv="$(tmux -L "$SOCK" display-message -p '#{pid}' 2>/dev/null)"
[ -n "$srv" ] && ! /usr/bin/grep -q 'roster\.lock' <<<"$(ls -l "/proc/$srv/fd" 2>/dev/null)" && ok "L: the tmux server started by start_one does not hold the roster lock" || no "L: tmux server keeps the roster lock fd" "server=$srv"
flock -n "$TD/.roster.lock" true && ok "L: the roster lock is free after launch-team exits" || no "L: roster lock free" ""
/usr/bin/grep -q "curated role 'orchestrator' not in active roster; this launcher does not start it" <<<"$out" && ok "L: a missing orchestrator names bin/start-orchestrator.sh" || no "L: orchestrator warning" ""
/usr/bin/grep -q "curated role 'communicator' not in active roster; start it with bin/communicator.sh" <<<"$out" && ok "L: a missing communicator names bin/communicator.sh" || no "L: communicator warning" ""
/usr/bin/grep -q 'add-role.sh orchestrator\|add-role.sh communicator' <<<"$out" && no "L: no add-role suggestion without goal and --reason" "" || ok "L: no unusable add-role suggestion"

out="$(sp bash "$R/bin/launch-team.sh" "$R/goals/g.md" alpha1)"; rc=$?; track
w="$(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null | /usr/bin/grep -cx alpha1)"
[ "$rc" = 0 ] && [ "$(lines_of alpha1)" = 1 ] && [ "$w" = 1 ] && ok "L: a second launch naming a live role does not spawn it again" || no "L: no double spawn" "rc=$rc lines=$(lines_of alpha1) windows=$w"
/usr/bin/grep -q "'alpha1' is already live; skipping" <<<"$out" && ok "L: says it skipped the live role" || no "L: skip line" "$out"

SHELLC2="$(start "$RID" bash -c 'sleep 600; :' claude)"; sleep 0.3      # args contain "claude"; not claude
printf '%s\t-\tshellc\n' "$SHELLC2" >> "$TD/active"
( flock 9; sleep 3; printf 'HOLDER\t-\tholder\n' >> "$TD/active" ) 9>"$TD/.roster.lock" & HOLD=$!
sleep 0.3
out="$(sp bash "$R/bin/launch-team.sh" "$R/goals/g.md" gamma1)"; rc=$?; wait "$HOLD"; track
/usr/bin/grep -q '^HOLDER' "$TD/active" && no "L: launch-team waits for the roster lock (it must reap the line the holder wrote)" "$(cat "$TD/active")" \
  || ok "L: launch-team waited for the roster lock (the holder's line was reaped after it, not lost to a race)"
[ "$(lines_of shellc)" = 0 ] && ok "L: reap drops a live process whose args only contain 'claude'" || no "L: reap by identity" "$(cat "$TD/active")"
[ "$(lines_of alpha1)" = 1 ] && [ "$(lines_of beta1)" = 1 ] && [ "$(lines_of gamma1)" = 1 ] && ok "L: POSITIVE reap keeps this run's live roles; gamma1 added" || no "L: live roles kept" "$(cat "$TD/active")"
# An npm-installed claude (argv[0] node) is live too: reading it as dead dropped live roles from
# active, made the cap count zero and let the double-spawn guard start a second copy.
NPMR="$(EXEC_A=node start "$RID" bash "$NPMCLI")"; settled "$NPMR"
printf '%s\t-\tnpm1\n' "$NPMR" >> "$TD/active"
r="$(sp bash -c '. "$1/bin/team-env.sh" && . "$1/bin/lib/team-spawn.sh" && reap_dead_keep_live; live_role_count; role_is_live npm1 && echo npm1-live' _ "$R")"
[ "$(lines_of npm1)" = 1 ] && ok "L: reap keeps a live npm-installed role (node .../@anthropic-ai/claude-code/cli.js)" || no "L: npm role reaped as dead" "$(cat "$TD/active")"
[ "$(head -1 <<<"$r")" = 4 ] && /usr/bin/grep -qx npm1-live <<<"$r" && ok "L: the npm-installed role counts toward the cap (4 live) and is live to the double-spawn guard" || no "L: npm role not live" "$r"
kill -9 "$NPMR" 2>/dev/null; sleep 0.3
# A pane pid is recorded while it is still the launching shell (bash -lc '... && exec claude ...'), not
# yet a claude: a reap in that interval dropped a live role. A live pid whose window is in this run's
# session is kept; a live non-claude whose window id is not in the session is still dropped.
PREX_WID="$(tmux -L "$SOCK" new-window -d -t "$SESS" -n prexec1 -P -F '#{window_id}' "sleep 600" 2>/dev/null)"
PREX="$(tmux -L "$SOCK" display-message -p -t "$PREX_WID" '#{pane_pid}' 2>/dev/null)"
printf '%s\t%s\tprexec1\n' "$PREX" "$PREX_WID" >> "$TD/active"
SHELLC4="$(start "$RID" bash -c 'sleep 600; :' claude)"; sleep 0.3
printf '%s\t@99999\tshellc4\n' "$SHELLC4" >> "$TD/active"
sp bash -c '. "$1/bin/team-env.sh" && . "$1/bin/lib/team-spawn.sh" && reap_dead_keep_live' _ "$R" >/dev/null
[ -n "$PREX" ] && [ "$(lines_of prexec1)" = 1 ] && ok "L: reap keeps a live pane pid that is not yet claude when its window is in this session" || no "L: pre-exec pane kept" "pid=$PREX wid=$PREX_WID $(cat "$TD/active")"
[ "$(lines_of shellc4)" = 0 ] && ok "L: reap drops a live non-claude whose window id is not in this session" || no "L: foreign window id dropped" "$(cat "$TD/active")"
tmux -L "$SOCK" kill-window -t "$PREX_WID" 2>/dev/null

out="$(sp bash "$R/bin/launch-team.sh" "$R/goals/g.md" reviewer-)"; rc=$?; track
[ "$rc" != 0 ] && /usr/bin/grep -q "invalid bus name 'reviewer-'" <<<"$out" && ok "L: launch-team refuses a trailing hyphen (reviewer-)" || no "L: reviewer- refused" "rc=$rc"
[ ! -e "$R/roles/reviewer-.md" ] && ok "L: no roles/reviewer-.md written" || no "L: roles/reviewer-.md written" ""
r="$(sp bash -c '. "$1/bin/team-env.sh" && . "$1/bin/lib/team-spawn.sh" && start_one reviewer-; echo "rc=$?"' _ "$R")"
/usr/bin/grep -q '^rc=1$' <<<"$r" && ok "L: start_one refuses reviewer- itself" || no "L: start_one reviewer-" "$r"

out="$(sp bash "$R/bin/add-role.sh" "$R/goals/g.md" delta1 --reason "   ")"; rc=$?
[ "$rc" = 2 ] && [ "$(lines_of delta1)" = 0 ] && ok "A: add-role refuses a blank --reason (exit 2, nothing spawned)" || no "A: blank reason" "rc=$rc $out"
out="$(sp bash "$R/bin/add-role.sh" "$R/goals/g.md" delta- --reason x)"; rc=$?
[ "$rc" = 1 ] && /usr/bin/grep -q "invalid bus name 'delta-'" <<<"$out" && ok "A: add-role refuses a trailing hyphen (delta-)" || no "A: delta- refused" "rc=$rc $out"
SHELLC3="$(start "$RID" bash -c 'sleep 600; :' claude)"; sleep 0.3
printf '%s\t-\tshellc3\n' "$SHELLC3" >> "$TD/active"
: > "$SB/curl.calls"
out="$(sp env MAX_TEAM_SIZE=4 bash "$R/bin/add-role.sh" "$R/goals/g.md" delta1 --reason "more hands")"; rc=$?; track; show "$out"
[ "$rc" = 0 ] && [ "$(lines_of delta1)" = 1 ] && ok "A: cap 4 with 3 live roles: a non-claude line in active does not count, delta1 added" || no "A: cap counts by identity" "rc=$rc"
[ ! -s "$SB/curl.calls" ] && ok "A: add-role does not push with curl" || no "A: curl called" "$(cat "$SB/curl.calls")"
/usr/bin/grep -q 'team grew: +delta1' "$SB/notify.sink.state/digest" 2>/dev/null && ok "A: the add is an info line in the operator digest" || no "A: digest line" ""
/usr/bin/grep -q 'team grew' "$SB/notify.sink" 2>/dev/null && no "A: info is never pushed" "" || ok "A: the add is not pushed"
RECYC="$(env ORCH_HOME="$R" TEAM_RUN_ID="$RID" TEAM_DIR="$TD" setsid bash "$SB/d/bin/tmux-watchdog.sh" >/dev/null 2>&1 & echo $!)"
echo "$RECYC" >> "$KIDS"; sleep 0.3
printf '%s\t-\tzeta1\n' "$RECYC" >> "$TD/active"
out="$(sp bash "$R/bin/retire-role.sh" zeta1 --no-graceful --reason gone)"; rc=$?
alive "$RECYC" && ok "A: retire does not signal a leader pid now held by this run's daemon (same ORCH_HOME and run id)" || no "A: recycled leader survives" "$out"
[ "$(lines_of zeta1)" = 0 ] && ok "A: the stale zeta1 line is removed" || no "A: zeta1 line removed" "$out"
D1="$(pid_of delta1)"
out="$(sp bash "$R/bin/retire-role.sh" delta1 --no-graceful --reason done)"; rc=$?; sleep 0.3
[ "$rc" = 0 ] && [ -n "$D1" ] && ! alive "$D1" && [ "$(lines_of delta1)" = 0 ] && ok "A: POSITIVE retire stops this run's role and drops its line" || no "A: retire delta1" "rc=$rc $out"
/usr/bin/grep -q 'team shrank: -delta1' "$SB/notify.sink.state/digest" 2>/dev/null && ok "A: the retire is an info line in the operator digest" || no "A: retire digest line" ""
[ ! -s "$SB/curl.calls" ] && ok "A: retire-role does not push with curl" || no "A: retire curl called" "$(cat "$SB/curl.calls")"
# A window of the name exists in this run's session, but active has no live line for it: start_one skips
# the name, so add-role logged, recorded and announced an add that spawned nothing, and exited 0.
tmux -L "$SOCK" new-window -d -t "$SESS" -n ghost1 "sleep 600" 2>/dev/null
out="$(sp bash "$R/bin/add-role.sh" "$R/goals/g.md" ghost1 --reason "late window")"; rc=$?; track
[ "$rc" = 1 ] && /usr/bin/grep -q "a window named 'ghost1' already exists" <<<"$out" && ok "A: add-role refuses a name whose window exists without a live line (exit 1)" || no "A: existing window refused" "rc=$rc $out"
/usr/bin/grep -q 'added ghost1\|+ghost1' "$TD/state.md" 2>/dev/null && no "A: no decision-log or roster line for the refused add" "$(cat "$TD/state.md")" || ok "A: no decision-log or roster line for the refused add"
/usr/bin/grep -q 'team grew: +ghost1' "$SB/notify.sink.state/digest" 2>/dev/null && no "A: no operator notice for the refused add" "" || ok "A: no operator notice for the refused add"
out="$(sp bash "$R/bin/add-role.sh" "$R/goals/g.md" ghost --auto-number --reason "next free")"; rc=$?; track
[ "$rc" = 0 ] && /usr/bin/grep -q 'auto-numbered role -> ghost2' <<<"$out" && [ "$(lines_of ghost2)" = 1 ] && ok "A: --auto-number skips the number whose window exists (ghost2 spawned)" || no "A: auto-number skips ghost1" "rc=$rc $out"

before="$(cat "$TD/active")"
out="$(sp env COMMUNICATOR_DISABLED=0 PATH="$SB/faketmux:$SB/fakebin:$PATH" bash "$R/bin/communicator.sh")"; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$TD/active")" = "$before" ] && ok "CM: a failed tmux call exits 1 and records nothing in active" || no "CM: failed new-window" "rc=$rc $out"
/usr/bin/grep -q 'launched communicator' <<<"$out" && no "CM: no 'launched' line after a failure" "$out" || ok "CM: no 'launched' line after a failure"
out="$(sp env COMMUNICATOR_DISABLED=0 bash "$R/bin/communicator.sh")"; rc=$?; track
case "$(pid_of communicator)" in ''|*[!0-9]*) no "CM: POSITIVE communicator recorded with its pid" "rc=$rc $out" ;; *) [ "$rc" = 0 ] && ok "CM: POSITIVE communicator launched and recorded with its pid" || no "CM: rc" "$rc" ;; esac
/usr/bin/grep -q 'inbound.jsonl' "$TD/communicator.prompt" && no "CM: the prompt no longer names inbound.jsonl" "" || ok "CM: the prompt no longer names inbound.jsonl"

RID2="$RID-so"; TD2="$R/.team-$RID2"
( PATH="$NOCL_PATH"; command -v claude >/dev/null ) && no "SO precondition: no claude on the stripped PATH" "" || ok "SO precondition: no claude on the stripped PATH"
out="$(sp env TEAM_RUN_ID="$RID2" PATH="$SB/fakebin:$NOCL_PATH" bash "$R/bin/start-orchestrator.sh")"; rc=$?; track "$TD2/active"
OP="$(pid_of orchestrator "$TD2/active" 2>/dev/null)"; sleep 0.5
[ "$rc" = 0 ] && [ -n "$OP" ] && ok "SO: start-orchestrator runs with CLAUDE_BIN and no claude on PATH" || no "SO: CLAUDE_BIN honoured" "rc=$rc $out"
/usr/bin/grep -qF "$STUB" "/proc/$OP/cmdline" 2>/dev/null && ok "SO: the orchestrator pane runs CLAUDE_BIN" || no "SO: pane runs CLAUDE_BIN" "$(tr '\0' ' ' < "/proc/$OP/cmdline" 2>&1)"

# The is-skill's list.py exits 1 ("not connected") when the launching shell has no bus listener.
# Under pipefail the communicator lookup used to end launch-team there, after the roles were up.
RID4="$RID-nolist"; TD4="$R/.team-$RID4"; mkdir -p "$SB/home/.claude/skills/is/bin"
cat > "$SB/home/.claude/skills/is/bin/list.py" <<EOF
import sys
open("$SB/list.calls", "a").write("called\n")
sys.stderr.write("not connected; join the bus first\n")
sys.exit(1)
EOF
out="$(sp env TEAM_RUN_ID="$RID4" COMMUNICATOR_DISABLED=0 bash "$R/bin/launch-team.sh" "$R/goals/g.md" eta1)"; rc=$?; track "$TD4/active"; show "$out"
[ -s "$SB/list.calls" ] && ok "L precondition: launch-team ran the stand-in list.py, which exited 1" || no "L precondition: list.py not run" "$out"
[ "$rc" = 0 ] && [ -n "$(pid_of eta1 "$TD4/active")" ] && ok "L: launch-team exits 0 when list.py reports 'not connected'" || no "L: a failed list.py ends launch-team" "rc=$rc"
[ "$(lines_of communicator "$TD4/active")" = 1 ] && ok "L: ... and still starts the communicator" || no "L: communicator not started after list.py failed" "$(cat "$TD4/active" 2>&1)"
/usr/bin/grep -q "curated role 'orchestrator' not in active roster" <<<"$out" && ok "L: ... and still runs the curated-role check" || no "L: curated-role check skipped after list.py failed" ""

# communicator.sh starts TEAM_ROLE_CMD, the command every other role runs, when CLAUDE_BIN is unset
# (tests/b9 sets only TEAM_ROLE_CMD). It used to need a claude on PATH and start the real one.
RID5="$RID-rolecmd"; TD5="$R/.team-$RID5"
out="$(sp env -u CLAUDE_BIN TEAM_RUN_ID="$RID5" COMMUNICATOR_DISABLED=0 PATH="$SB/fakebin:$NOCL_PATH" bash "$R/bin/communicator.sh")"; rc=$?; track "$TD5/active"
CP="$(pid_of communicator "$TD5/active" 2>/dev/null)"; sleep 0.5
[ "$rc" = 0 ] && [ -n "$CP" ] && ok "CM: communicator.sh runs with TEAM_ROLE_CMD, no CLAUDE_BIN and no claude on PATH" || no "CM: TEAM_ROLE_CMD honoured" "rc=$rc $out"
/usr/bin/grep -qF "$STUB" "/proc/$CP/cmdline" 2>/dev/null && ok "CM: the communicator pane runs TEAM_ROLE_CMD (the stand-in)" || no "CM: pane runs TEAM_ROLE_CMD" "$(tr '\0' ' ' < "/proc/$CP/cmdline" 2>&1)"

RID3="$RID-logs"; TD3="$R/.team-$RID3"; mkdir -p "$TD3" "$SB/dsave"
dl="api-watchdog tmux-watchdog host-ram-watchdog disk-tmp-watchdog observer permission-mode-watchdog chrome-supervisor"
for n in $dl; do
  cp "$R/bin/$n.sh" "$SB/dsave/"
  printf '#!/usr/bin/env bash\necho $$ >> "%s"\nwhile :; do echo "%s line"; sleep 0.2; done\n' "$KIDS" "$n" > "$R/bin/$n.sh"
  echo OLD > "$TD3/$n.log"
done
printf 'import time\nwhile True:\n    print("poller line", flush=True)\n    time.sleep(0.2)\n' > "$SB/poller.py"; echo OLD > "$TD3/intake-poller.log"
out="$(env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION TEAM_RUN_ID="$RID3" TEAM_TMUX="$SOCK" HOME="$SB/home" INTAKE_POLLER="$SB/poller.py" \
  bash -c '. "$1/bin/team-env.sh" && repo="$1" && . "$1/bin/lib/team-spawn.sh" && start_api_watchdog && start_tmux_watchdog && start_host_ram_watchdog \
    && start_disk_tmp_watchdog && start_observer && start_permission_mode_watchdog && start_chrome_supervisor && start_intake_poller' _ "$R" 2>&1 9>&-)"
cat "$TD3/intake-poller.pid" >> "$KIDS" 2>/dev/null; sleep 0.8
kept=""; for n in $dl intake-poller; do [ "$(head -1 "$TD3/$n.log")" = OLD ] || kept="$kept $n"; done
[ -z "$kept" ] && ok "D: every daemon log keeps its old content (opened with >>)" || no "D: logs truncated at start" "$kept $out"
for n in $dl intake-poller; do : > "$TD3/$n.log"; done; sleep 0.8
# Readiness, not only a fixed sleep: under load a stand-in can be slow to write its next line. Wait up
# to 5 s more until every log has regrown.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  silent=""; for n in $dl intake-poller; do [ -s "$TD3/$n.log" ] || silent="$silent $n"; done
  [ -z "$silent" ] && break; sleep 0.5
done
nul=""; for n in $dl intake-poller; do
  # Count the NUL bytes in one read: comparing two sizes read one after the other failed whenever
  # the daemon wrote a line between the reads (seen under load).
  [ -s "$TD3/$n.log" ] && [ "$(tr -cd '\000' < "$TD3/$n.log" | wc -c)" = 0 ] \
    || nul="$nul $n($(wc -c < "$TD3/$n.log") bytes, $(tr -cd '\000' < "$TD3/$n.log" | wc -c) NUL)"; done
[ -z "$nul" ] && ok "D: a log truncated by the rotation keeps growing without NUL bytes" || no "D: NUL-filled or silent logs" "$nul"
for n in $dl; do cp "$SB/dsave/$n.sh" "$R/bin/$n.sh"; done

# team-status.sh decides ALIVE as the teardown scripts do: this run's claude by what it executes, not
# "claude" somewhere in the args line.
RID6="$RID-status"; TD6="$R/.team-$RID6"; mkdir -p "$TD6"
TS_ROLE="$(EXEC_A=claude start "$RID6" sleep 600)"
TS_WORD="$(start "$RID6" bash -c 'sleep 600; :' claude)"
TS_OTHER="$(EXEC_A=claude start "other-$$" sleep 600)"
settled "$TS_ROLE" "$TS_WORD" "$TS_OTHER"
printf '%s\t-\tts-role\n%s\t-\tts-word\n%s\t-\tts-other\n' "$TS_ROLE" "$TS_WORD" "$TS_OTHER" > "$TD6/active"
out="$(sp env TEAM_RUN_ID="$RID6" bash "$R/bin/team-status.sh")"; show "$out"
col(){ awk -v r="$1" -v c="$2" '$1==r {print $c}' <<<"$out"; }
[ "$(col ts-role 3)" = yes ] && ok "TS: this run's claude reads ALIVE yes" || no "TS: role alive" "$out"
[ "$(col ts-word 3)" = NO ] && ok "TS: a shell whose args contain 'claude' reads ALIVE NO" || no "TS: args word" "$out"
[ "$(col ts-other 3)" = NO ] && ok "TS: another run's claude named in active reads ALIVE NO" || no "TS: other run's claude" "$out"
out="$(sp env TEAM_RUN_ID="$RID6" bash "$R/bin/team-status.sh" --mobile)"
[ "$(col ts-role 2)/$(col ts-word 2)/$(col ts-other 2)" = "y/X/X" ] && ok "TS --mobile: y for this run's claude, X for the other two" || no "TS --mobile" "$out"

empty=""
for role in orchestrator communicator reviewer1 tester2 architect1 analyst1 devops1 copy-editor1 paralegal1 doc-integrator1 relay1 poller1 implementer1 novel-role1; do
  var="TEAM_MODEL_$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')"
  m="$(env TEAM_MODEL_TOP= TEAM_MODEL_DEFAULT= "$var=" bash -c '. "$1/bin/lib/team-spawn.sh" && model_for "$2"' _ "$R" "$role")"
  [ -n "$m" ] || empty="$empty $role"
done
[ -z "$empty" ] && ok "M: model_for prints a model for every tier even with every override set empty" || no "M: empty model for" "$empty"
reset_procs

# The socket FILE is this test's too: it existed while the server ran, and is gone after.
tmux_kill_unlink tmux "$SOCK"
sp="$(tmux_sock_path "$SOCK")"
[ "${SOCK_SEEN:-0}" = 1 ] && ok "tmux socket file existed while the server ran ($sp)" || no "tmux socket file never seen at $sp" ""
[ ! -e "$sp" ] && ok "tmux socket file removed after the run" || no "tmux socket file left behind: $sp" ""
echo "=== result: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

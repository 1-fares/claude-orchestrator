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
reset_procs

# Panic scenario. Sets globals for the asserts.
panic_scenario(){
  mkdir -p "$TD"
  env TEAM_RUN_ID="$RID" TEAM_DIR="$TD" tmux -L "$SOCK" new-session -d -s "$SESS" "sleep 600"
  [ -S "$(tmux_sock_path "$SOCK")" ] && SOCK_SEEN=1
  PANE="$(tmux -L "$SOCK" list-panes -s -t "$SESS" -F '#{pane_pid}' 2>/dev/null | head -1)"
  ROLE="$(EXEC_A=claude start "$RID" sleep 600)"                     # this run's role, detached
  ROLE_OTHER="$(EXEC_A=claude start "other-$$" sleep 600)"          # another run's claude
  SHELLC="$(start "$RID" bash -c 'sleep 600; :' claude)"             # args contain "claude"
  BARE="$(start - sleep 600)"                                        # no run env (sshd-like)
  TWD="$(start "$RID" bash "$SB/d/bin/tmux-watchdog.sh")"            # this run's daemon
  FOREIGN="$(start "other-$$" bash "$SB/d/bin/chrome-supervisor.sh")" # another run's daemon
  SRV="$(start "$RID" python3 "$SB/d/bin/server.py" --fd 8 --host 127.0.0.1 --port "$PORT")"
  SRV_FX="$(start "other-$$" python3 "$SB/d/bin/server.py" --port "$PORT")"
  sleep 0.6
  printf '%s\t-\tbuilder\n%s\t-\tother\n%s\t-\tshellc\n' "$ROLE" "$ROLE_OTHER" "$SHELLC" > "$TD/active"
  echo "$TWD"     > "$TD/tmux-watchdog.pid"
  echo "$FOREIGN" > "$TD/chrome-supervisor.pid"
  echo "$BARE"    > "$TD/observer.pid"
}
panic_pre(){ local p bad=""
  for p in $PANE $ROLE $ROLE_OTHER $SHELLC $BARE $TWD $FOREIGN $SRV $SRV_FX; do alive "$p" || bad="$bad $p"; done
  [ -n "$PANE" ] || bad="$bad no-pane"
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
alive "$TWD" && no "P: POSITIVE daemon killed" "" || ok "P: POSITIVE this run's tmux-watchdog KILLED"
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

# The socket FILE is this test's too: it existed while the server ran, and is gone after.
tmux_kill_unlink tmux "$SOCK"
sp="$(tmux_sock_path "$SOCK")"
[ "${SOCK_SEEN:-0}" = 1 ] && ok "tmux socket file existed while the server ran ($sp)" || no "tmux socket file never seen at $sp" ""
[ ! -e "$sp" ] && ok "tmux socket file removed after the run" || no "tmux socket file left behind: $sp" ""
echo "=== result: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

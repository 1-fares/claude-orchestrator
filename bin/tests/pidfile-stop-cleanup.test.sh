#!/usr/bin/env bash
# Test: bin/stop-team.sh and bin/cleanup.sh signal a pid read from a file (a daemon pidfile, the bus
# pidfile, .team/active) only when it is THIS run's process.
#
# Before: `kill -0` (daemons) or "args contain claude" (roles) was the whole check, so after a reboot
# or pid wrap a stale pidfile could aim TERM/KILL -- for roles a PROCESS-GROUP kill -- at sshd, the
# SSM agent, a `tail -f ~/.claude/...` or another run's daemon.
#
# Every case asserts both directions: an unrelated live process named by a file SURVIVES, and a real
# fake daemon of this run IS stopped (the positive control: a gate that signals nothing passes the
# first half alone).
#
# ISOLATION. The scripts under test run from a COPY of bin/ in a sandbox repo, never from this tree:
# cleanup.sh --force reaps every /is client whose environ has ORCH_HOME=<its own repo>, and from the
# live engine tree that is the live team. HOME is sandboxed (the bus pidfile dir), TEAM_TMUX is a
# throwaway socket (team-env defaults to the live one), stop-team runs --no-graceful (no pane
# typing), NOTIFY_SINK/WATCH_ALERT_SINK are scratch files. Every process the test starts is setsid'd
# into its own group, so a group kill can never reach this shell.
#
# SRC=<engine tree> runs the scripts of another tree (for the red run against the old code).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${SRC:-$repo}"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
alive(){ [ -d "/proc/$1" ] && ! /usr/bin/grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

SB="$(mktemp -d /tmp/pidstop-XXXXXX)"
RID="pidstop-$$"
R="$SB/repo"                  # the sandbox engine repo the scripts run from
TD="$R/.team-$RID"
SOCK="ttps$$"
export NOTIFY_SINK="$SB/notify.sink" WATCH_ALERT_SINK="$SB/watch.sink"
KIDS="$SB/kids"
cleanup(){ local k; while read -r k; do pkill -9 -P "$k" 2>/dev/null; kill -9 "$k" 2>/dev/null || true; done < "$KIDS"
           tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf -- "${SB:?}"; }
trap cleanup EXIT
mkdir -p "$R" "$SB/d/bin" "$SB/home/.claude/data/inter-session"; : > "$KIDS"
cp -a "$SRC/bin" "$R/bin"
[ -f "$SRC/CLAUDE.md" ] && cp "$SRC/CLAUDE.md" "$R/"
case "$R" in "$SB"/*) ;; *) echo "FATAL: sandbox repo is not under the sandbox: $R" >&2; exit 99 ;; esac

# Fake daemons: real processes whose program position is the daemon script.
for n in api-watchdog tmux-watchdog compaction-watchdog observer chrome-supervisor; do
  printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$SB/d/bin/$n.sh"
done
# A resource watchdog keeps a backgrounded sleep child and, like bin/host-ram-watchdog.sh, reaps it
# from its TERM trap (pkill -P in the scripts is the fallback for pre-trap code).
printf '#!/usr/bin/env bash\nk=""; trap '"'"'[ -n "$k" ] && kill "$k" 2>/dev/null; exit 0'"'"' TERM\nwhile true; do sleep 30 & k=$!; wait $k; done\n' > "$SB/d/bin/host-ram-watchdog.sh"
# The intake poller at a PROJECT path, configured in project.conf only (as team-spawn reads it).
mkdir -p "$SB/d/custom"; printf 'import time\nwhile True: time.sleep(1)\n' > "$SB/d/custom/my-poller.py"
printf 'INTAKE_POLLER="%s"\n' "$SB/d/custom/my-poller.py" > "$R/project.conf"
printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$SB/d/bin/disk-tmp-watchdog.sh"
printf 'import sys, time\nwhile True: time.sleep(1)\n' > "$SB/d/bin/server.py"
chmod +x "$SB"/d/bin/*.sh

PORT="$( export TEAM_RUN_ID="$RID"; unset TEAM_DIR TEAM_PORT INTER_SESSION_PORT; repo="$R"; . "$R/bin/team-env.sh" >/dev/null 2>&1; echo "$TEAM_PORT" )"
[ -n "$PORT" ] || { echo "FATAL: could not derive the sandbox run's TEAM_PORT" >&2; exit 99; }
BUSPF="$SB/home/.claude/data/inter-session/server.$PORT.pid"

# start <run-id|-> <argv...>: setsid'd background process; "-" = no run identity in its environ.
# exec -a is available through EXEC_A=<argv0>. "dir-only" = this run's TEAM_DIR, no TEAM_RUN_ID.
start(){ local r="$1"; shift
  if [ "$r" = dir-only ]; then
    env -u TEAM_RUN_ID TEAM_DIR="$TD" setsid ${EXEC_A:+bash -c 'exec -a "$0" "$@"' "$EXEC_A"} "$@" >/dev/null 2>&1 &
  elif [ "$r" = - ]; then
    env -u TEAM_RUN_ID -u TEAM_DIR setsid ${EXEC_A:+bash -c 'exec -a "$0" "$@"' "$EXEC_A"} "$@" >/dev/null 2>&1 &
  else
    env TEAM_RUN_ID="$r" TEAM_DIR="$R/.team-$r" setsid ${EXEC_A:+bash -c 'exec -a "$0" "$@"' "$EXEC_A"} "$@" >/dev/null 2>&1 &
  fi
  local p=$!; echo "$p" >> "$KIDS"; echo "$p"; }
child_of(){ pgrep -P "$1" 2>/dev/null | head -1; }
run_stop(){ env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" \
              bash "$R/bin/stop-team.sh" --no-graceful 2>&1; }
run_cleanup(){ env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u ORCH_HOME TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" \
              bash "$R/bin/cleanup.sh" "$@" 2>&1; }
show(){ printf '%s\n' "$1" | sed 's/^/     | /'; }

# scenario: start the processes, write the files. Sets globals for the asserts.
scenario(){
  mkdir -p "$TD"
  UNREL="$(start "$RID" sleep 600)"                                  # this run's env, not a daemon
  BARE="$(start - sleep 600)"                                         # no run env at all (sshd-like)
  FOREIGN="$(start "other-$$" bash "$SB/d/bin/chrome-supervisor.sh")" # same script, another run
  TAIL="$(start "$RID" tail -f "$SB/d/bin/compaction-watchdog.sh")"   # mentions the script, same run
  SHELLC="$(start "$RID" bash -c 'sleep 600; :' claude)"              # args contain "claude"
  TWD="$(start "$RID" bash "$SB/d/bin/tmux-watchdog.sh")"             # REAL daemons of this run
  HRW="$(start "$RID" bash "$SB/d/bin/host-ram-watchdog.sh")"
  POLL="$(start "$RID" python3 -u "$SB/d/custom/my-poller.py")"              # project-path poller
  SHW="$(start dir-only bash "$SB/d/bin/disk-tmp-watchdog.sh")"             # TEAM_DIR only
  # A role that ignores TERM, with a child that ignores it too: only the SIGKILL path stops it.
  STUB="$(EXEC_A=claude start "$RID" bash -c 'trap "" TERM; sleep 600 & wait; :')"
  # A role that exits on TERM and leaves an ORPHAN in its process group that ignores TERM (not a
  # descendant any more, so only a group kill reaches it).
  QUICK="$(EXEC_A=claude start "$RID" bash -c '( ( trap "" TERM; exec sleep 600 ) & ); sleep 600; :')"
  ROLE="$(EXEC_A=claude start "$RID" sleep 600)"                      # argv0 claude, this run
  ROLE_OTHER="$(EXEC_A=claude start "other-$$" sleep 600)"           # argv0 claude, another run
  sleep 0.6
  HRW_KID="$(child_of "$HRW")"
  STUB_KID="$(child_of "$STUB")"
  ORPHAN="$(ps -eo pid=,pgid=,ppid= | awk -v g="$QUICK" '$2==g && $1!=g && $3!=g {print $1; exit}')"
  [ -n "$ORPHAN" ] && echo "$ORPHAN" >> "$KIDS"
  echo "$UNREL"   > "$TD/api-watchdog.pid"
  echo "$BARE"    > "$TD/observer.pid"
  echo "$FOREIGN" > "$TD/chrome-supervisor.pid"
  echo "$TAIL"    > "$TD/compaction-watchdog.pid"
  echo "$TWD"     > "$TD/tmux-watchdog.pid"
  echo "$HRW"     > "$TD/host-ram-watchdog.pid"
  echo "$POLL"    > "$TD/intake-poller.pid"
  echo "$SHW"     > "$TD/disk-tmp-watchdog.pid"
  printf '%s\t-\tbuilder\n%s\t-\tshellc\n%s\t-\tother\n%s\t-\tbare\n%s\t-\tstubborn\n%s\t-\tquick\n999999999\t-\tgone\n' \
    "$ROLE" "$SHELLC" "$ROLE_OTHER" "$BARE" "$STUB" "$QUICK" > "$TD/active"
}
preconditions(){
  local p bad=""
  for p in $UNREL $BARE $FOREIGN $TAIL $SHELLC $TWD $HRW $POLL $SHW $ROLE $ROLE_OTHER $STUB $QUICK; do alive "$p" || bad="$bad $p"; done
  [ -n "$HRW_KID" ] && alive "$HRW_KID" || bad="$bad hrw-child"
  [ -n "$STUB_KID" ] && alive "$STUB_KID" || bad="$bad stubborn-child"
  [ -n "$ORPHAN" ] && alive "$ORPHAN" || bad="$bad quick-orphan"
  /usr/bin/grep -qx "TEAM_RUN_ID=$RID" <<<"$( { tr '\0' '\n' < "/proc/$SHW/environ"; } 2>/dev/null )" && bad="$bad shw-has-run-id"
  [ "$(tr '\0' ' ' < "/proc/$ROLE/cmdline")" = "claude 600 " ] || bad="$bad role-argv0"
  [ -z "$bad" ] && ok "$1 preconditions: all fixture processes alive, role argv0 is claude" || no "$1 preconditions" "dead/wrong:$bad"
}
asserts(){   # <label> <output>
  local L="$1" out="$2"
  alive "$UNREL"   && ok "$L: api-watchdog.pid -> unrelated same-run sleep SURVIVES"     || no "$L: unrelated sleep survives" ""
  alive "$BARE"    && ok "$L: observer.pid -> process with no run env SURVIVES"         || no "$L: bare process survives" ""
  alive "$FOREIGN" && ok "$L: chrome-supervisor.pid -> another run's daemon SURVIVES"   || no "$L: foreign daemon survives" ""
  alive "$TAIL"    && ok "$L: compaction-watchdog.pid -> tail -f <script> SURVIVES"     || no "$L: tail survives" ""
  alive "$SHELLC"  && ok "$L: active -> a shell whose args contain 'claude' SURVIVES"   || no "$L: args-claude shell survives" ""
  alive "$ROLE_OTHER" && ok "$L: active -> another run's claude SURVIVES"               || no "$L: other run's claude survives" ""
  alive "$TWD"  && no "$L: POSITIVE tmux-watchdog stopped" "" || ok "$L: POSITIVE this run's tmux-watchdog STOPPED"
  alive "$HRW"  && no "$L: POSITIVE host-ram-watchdog stopped" "" || ok "$L: POSITIVE this run's host-ram-watchdog STOPPED"
  alive "$HRW_KID" && no "$L: POSITIVE host-ram sleep child reaped" "" || ok "$L: POSITIVE its sleep child reaped (pkill -P)"
  alive "$POLL" && no "$L: POSITIVE intake-poller stopped" "" || ok "$L: POSITIVE this run's intake-poller (python3 -u) STOPPED"
  alive "$ROLE" && no "$L: POSITIVE role claude stopped" "" || ok "$L: POSITIVE this run's role claude STOPPED"
  alive "$POLL" || ok "$L: POSITIVE poller at a project.conf path (not a default glob) STOPPED"
  alive "$SHW"  && no "$L: POSITIVE TEAM_DIR-only daemon stopped" "" || ok "$L: POSITIVE daemon carrying only TEAM_DIR STOPPED"
  alive "$STUB" && no "$L: POSITIVE TERM-ignoring role killed (SIGKILL path)" "" || ok "$L: POSITIVE TERM-ignoring role KILLED (SIGKILL path)"
  alive "$STUB_KID" && no "$L: POSITIVE its TERM-ignoring child killed" "" || ok "$L: POSITIVE its TERM-ignoring child KILLED (group)"
  alive "$QUICK" && no "$L: POSITIVE TERM-exiting role stopped" "" || ok "$L: POSITIVE TERM-exiting role STOPPED"
  local f n
  for f in api-watchdog observer chrome-supervisor compaction-watchdog tmux-watchdog host-ram-watchdog intake-poller disk-tmp-watchdog; do
    [ -f "$TD/$f.pid" ] && no "$L: $f.pid removed" "" || :
  done
  [ -d "$TD" ] && [ -n "$(ls "$TD"/*.pid 2>/dev/null)" ] && no "$L: every stale pidfile removed" "$(ls "$TD")" || ok "$L: every pidfile (ours, in TEAM_DIR) removed"
  for n in "$UNREL api-watchdog" "$BARE observer" "$FOREIGN chrome-supervisor" "$TAIL compaction-watchdog"; do
    set -- $n
    /usr/bin/grep -qE "skip $2: pid $1 from .*/$2\.pid .*not signalled" <<<"$out" \
      && ok "$L: one skip line names pid $1, $2.pid and why" || no "$L: skip line for $2 (pid $1)" ""
  done
  /usr/bin/grep -qE "skip (recorded role '?)?shellc'?: pid $SHELLC from .*active .*not signalled" <<<"$out" \
    && ok "$L: one skip line for the args-claude shell in active" || no "$L: skip line for shellc (pid $SHELLC)" ""
  /usr/bin/grep -q "pid 999999999" <<<"$out" && no "$L: a dead pid is not reported as a skip" "" || ok "$L: dead pid: silent, pidfile removed"
}
reset_procs(){ local k; while read -r k; do pkill -9 -P "$k" 2>/dev/null; kill -9 "$k" 2>/dev/null || true; done < "$KIDS"; : > "$KIDS"; sleep 0.3; }

echo "=== S: stop-team.sh ($SRC) ==="
scenario; preconditions S
out="$(run_stop)"; sleep 0.8
show "$out"; asserts S "$out"
reset_procs

echo "=== S-bus: the /is bus pidfile ==="
mkdir -p "$TD"
UNREL="$(start "$RID" sleep 600)"; sleep 0.3
echo "$UNREL" > "$BUSPF"
out="$(run_stop)"; sleep 0.5
alive "$UNREL" && ok "bus pidfile -> unrelated same-run sleep SURVIVES" || no "bus: unrelated survives" "$out"
SRV_OTHER="$(start "$RID" python3 "$SB/d/bin/server.py" --host 127.0.0.1 --port 1)"
SRV="$(start "$RID" python3 "$SB/d/bin/server.py" --fd 8 --host 127.0.0.1 --port "$PORT")"; sleep 0.4
echo "$SRV_OTHER" > "$BUSPF"
out="$(run_stop)"; sleep 0.5
alive "$SRV_OTHER" && ok "bus pidfile -> this run's server.py on ANOTHER port SURVIVES" || no "bus: other-port server survives" "$out"
echo "$SRV" > "$BUSPF"
out="$(run_stop)"; sleep 0.5; show "$out"
alive "$SRV" && no "bus: POSITIVE server stopped" "$out" || ok "bus: POSITIVE this run's server.py on port $PORT STOPPED"
reset_procs

echo "=== C: cleanup.sh --force ($SRC) ==="
scenario; preconditions C
out="$(run_cleanup --force)"; sleep 0.8
show "$out"; asserts C "$out"
alive "$ORPHAN" && no "C: POSITIVE orphan left in the TERM-exiting role's group killed (group kill after the root exited)" "" \
  || ok "C: POSITIVE orphan in the exited role's process group KILLED"
reset_procs

echo "=== C-dry: cleanup.sh dry run signals nothing ==="
scenario
out="$(run_cleanup)"; sleep 0.5
alive "$TWD" && alive "$ROLE" && alive "$POLL" && ok "dry run: real daemons and role untouched" || no "dry run signalled" "$out"
[ -f "$TD/tmux-watchdog.pid" ] && [ -f "$TD/api-watchdog.pid" ] && ok "dry run: pidfiles kept" || no "dry run kept pidfiles" ""
/usr/bin/grep -q "\[would\] kill tmux-watchdog (pid $TWD)" <<<"$out" && ok "dry run: would kill the real tmux-watchdog" || no "dry run plan line" "$out"
reset_procs

echo "=== result: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

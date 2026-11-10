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
# Teardown sections at the end:
#   R   reset.sh, panic.sh, stop-team.sh and cleanup.sh exit 1 when team-env.sh refuses a pre-set
#       TEAM_DIR (reset.sh used to go on and `rm -rf` it); tdg_guard_rmrf_owned units; reset.sh and
#       cleanup.sh --force refuse to remove an explicit TEAM_DIR_ALLOW_OVERRIDE dir; reset.sh keeps
#       the run dir and exits 1 when panic.sh exits non-zero; positive controls remove the
#       canonical run dir.
#   ST  stop-team.sh: the observer's whole tree (a model call in progress) is reaped; a daemon that
#       ignores TERM is SIGKILLed after a re-check; a window id from active that belongs to another
#       session is neither typed into nor killed, while this run's window is killed; active keeps
#       the line of the orchestrator left running.
#   SL  stop-team.sh keeps the line of a live role appended to active while it waited for the
#       roster lock, and drops the line of the role it stopped.
#   OT  panic.sh and cleanup.sh --force reap the observer's whole tree, captured before the TERM.
#   The R guard rows also refuse a TEAM_RUN_ID with a slash and a run dir that resolves outside
#   the clone.
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
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/tmux-socket.sh"
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
           tmux_kill_unlink tmux "$SOCK";rm -rf -- "${SB:?}"; }
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
# A daemon whose TERM trap waits for a FOREGROUND sleep, like bin/api-watchdog.sh: TERM alone leaves it
# (and the flock fd its sleep inherits) for up to 30 s; only pkill -P ends it at once.
printf '#!/usr/bin/env bash\ntrap "exit 0" TERM\nwhile true; do sleep 30; done\n' > "$SB/d/bin/permission-mode-watchdog.sh"
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
  PMW="$(start "$RID" bash "$SB/d/bin/permission-mode-watchdog.sh")"
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
  PMW_KID="$(child_of "$PMW")"; [ -n "$PMW_KID" ] && echo "$PMW_KID" >> "$KIDS"
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
  echo "$PMW"     > "$TD/permission-mode-watchdog.pid"
  printf '%s\t-\tbuilder\n%s\t-\tshellc\n%s\t-\tother\n%s\t-\tbare\n%s\t-\tstubborn\n%s\t-\tquick\n999999999\t-\tgone\n' \
    "$ROLE" "$SHELLC" "$ROLE_OTHER" "$BARE" "$STUB" "$QUICK" > "$TD/active"
}
preconditions(){
  local p bad=""
  for p in $UNREL $BARE $FOREIGN $TAIL $SHELLC $TWD $HRW $PMW $POLL $SHW $ROLE $ROLE_OTHER $STUB $QUICK; do alive "$p" || bad="$bad $p"; done
  [ -n "$HRW_KID" ] && alive "$HRW_KID" || bad="$bad hrw-child"
  [ -n "$PMW_KID" ] && alive "$PMW_KID" || bad="$bad pmw-child"
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
  alive "$PMW" && no "$L: POSITIVE permission-mode-watchdog stopped" "" || ok "$L: POSITIVE this run's permission-mode-watchdog (TERM trap, foreground sleep) STOPPED"
  alive "$PMW_KID" && no "$L: POSITIVE permission-mode-watchdog's foreground sleep reaped" "" || ok "$L: POSITIVE its foreground sleep child reaped (pkill -P)"
  alive "$POLL" && no "$L: POSITIVE intake-poller stopped" "" || ok "$L: POSITIVE this run's intake-poller (python3 -u) STOPPED"
  alive "$ROLE" && no "$L: POSITIVE role claude stopped" "" || ok "$L: POSITIVE this run's role claude STOPPED"
  alive "$POLL" || ok "$L: POSITIVE poller at a project.conf path (not a default glob) STOPPED"
  alive "$SHW"  && no "$L: POSITIVE TEAM_DIR-only daemon stopped" "" || ok "$L: POSITIVE daemon carrying only TEAM_DIR STOPPED"
  alive "$STUB" && no "$L: POSITIVE TERM-ignoring role killed (SIGKILL path)" "" || ok "$L: POSITIVE TERM-ignoring role KILLED (SIGKILL path)"
  alive "$STUB_KID" && no "$L: POSITIVE its TERM-ignoring child killed" "" || ok "$L: POSITIVE its TERM-ignoring child KILLED (group)"
  alive "$QUICK" && no "$L: POSITIVE TERM-exiting role stopped" "" || ok "$L: POSITIVE TERM-exiting role STOPPED"
  local f n
  for f in api-watchdog observer chrome-supervisor compaction-watchdog tmux-watchdog host-ram-watchdog intake-poller disk-tmp-watchdog permission-mode-watchdog; do
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

# run_env [VAR=value ...] -- <script> [args]: a teardown script of the sandbox under this run, with
# extra environment (a pre-set TEAM_DIR, TEAM_DIR_ALLOW_OVERRIDE) on top of the clean one.
run_env(){ local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION -u ORCH_HOME -u TEAM_DIR_ALLOW_OVERRIDE \
    TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" "${e[@]}" bash "$R/bin/$1" "${@:2}" 2>&1; }
desc(){ local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; desc "$c"; done; }

echo "=== R: teardown scripts on a refused TEAM_DIR, and the run-dir ownership guard ($SRC) ==="
DECOY="$SB/decoy-run"
for s in reset.sh panic.sh stop-team.sh cleanup.sh; do
  mkdir -p "$DECOY"; echo keep > "$DECOY/marker"
  a=(); [ "$s" = cleanup.sh ] && a=(--force); [ "$s" = stop-team.sh ] && a=(--no-graceful)
  out="$(run_env TEAM_DIR="$DECOY" -- "$s" "${a[@]}")"; rc=$?
  [ "$rc" = 1 ] && ok "R $s: exits 1 when team-env refuses a pre-set TEAM_DIR" || no "R $s: exit 1 on the refusal" "rc=$rc"
  [ -f "$DECOY/marker" ] && ok "R $s: the refused TEAM_DIR survives" || no "R $s: refused TEAM_DIR survives" "$out"
  /usr/bin/grep -q 'unbound variable' <<<"$out" && no "R $s: stops at the refusal, not at a later unbound variable" "$out" \
    || ok "R $s: stops at the refusal, not at a later unbound variable"
done
# gu <env...>: tdg_guard_rmrf_owned "$GP" with only the given TEAM_REPO/TEAM_RUN_ID.
gu(){ env -u TEAM_DIR -u TEAM_RUN_ID -u TEAM_REPO "$@" bash -c '. "$0/bin/lib/team-dir-guard.sh" && tdg_guard_rmrf_owned "$1"' "$R" "$GP" 2>/dev/null; }
mkdir -p "$TD"
GP="$TD";           gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && ok "R guard: this run's canonical dir is owned" || no "R guard: canonical dir owned" ""
GP="$TD/";          gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && ok "R guard: the canonical dir with a trailing slash is owned" || no "R guard: trailing slash" ""
GP="$R/.team";      gu TEAM_REPO="$R" && ok "R guard: legacy .team is owned with no TEAM_RUN_ID" || no "R guard: legacy .team owned" ""
GP="$R/.team-other"; gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && no "R guard: another run's dir refused" "" || ok "R guard: another run's dir in the same clone REFUSED"
GP="$R/.team";      gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && no "R guard: legacy dir refused for a per-run session" "" || ok "R guard: legacy .team REFUSED for a per-run session"
GP="$SB";           gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && no "R guard: a non-run dir refused" "" || ok "R guard: a dir that is not a run dir REFUSED"
GP="/";             gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && no "R guard: / refused" "" || ok "R guard: / REFUSED"
GP="$TD";           gu TEAM_RUN_ID="$RID" && no "R guard: unset TEAM_REPO refused" "" || ok "R guard: unset TEAM_REPO REFUSED"
GP="";              gu TEAM_REPO="$R" TEAM_RUN_ID="$RID" && no "R guard: empty path refused" "" || ok "R guard: empty path REFUSED"
# A run id with a slash names no run dir, and each of these equals its own canonical path: "x/../../escaped"
# resolves outside the clone, "x/../inner" onto one of its directories. A .team-<id> that is a symlink
# resolves outside the clone too.
mkdir -p "$SB/escaped" "$R/inner"; ln -s "$SB/escaped" "$R/.team-lnk"
GP="$SB/escaped";   gu TEAM_REPO="$R" TEAM_RUN_ID="x/../../escaped" && no "R guard: a run id resolving outside the clone refused" "" || ok "R guard: TEAM_RUN_ID x/../../escaped (outside the clone) REFUSED"
GP="$R/inner";      gu TEAM_REPO="$R" TEAM_RUN_ID="x/../inner" && no "R guard: a run id with a slash refused" "" || ok "R guard: TEAM_RUN_ID x/../inner (a directory of the clone) REFUSED"
GP="$R/.team-lnk";  gu TEAM_REPO="$R" TEAM_RUN_ID="lnk" && no "R guard: a run dir that is a symlink out of the clone refused" "" || ok "R guard: a .team-<id> symlink out of the clone REFUSED"
[ -d "$TD" ] && ok "R guard: the guard itself deletes nothing" || no "R guard: the guard deleted the dir" ""
EXPL="$SB/explicit-dir"
for s in reset.sh cleanup.sh; do
  mkdir -p "$EXPL"; echo keep > "$EXPL/marker"
  a=(); [ "$s" = cleanup.sh ] && a=(--force)
  out="$(run_env TEAM_DIR="$EXPL" TEAM_DIR_ALLOW_OVERRIDE=1 -- "$s" "${a[@]}")"; rc=$?
  [ "$rc" != 0 ] && [ -f "$EXPL/marker" ] && ok "R $s: an explicit TEAM_DIR_ALLOW_OVERRIDE dir is not removed (rc $rc)" || no "R $s: explicit dir kept" "rc=$rc $out"
  /usr/bin/grep -q "REFUSING rm -rf '$EXPL'" <<<"$out" && ok "R $s: the ownership guard names the dir it refused" || no "R $s: guard refusal line" "$out"
done
# reset.sh when panic.sh exits non-zero (survivors, or the session still up): a stand-in panic.sh.
cp "$R/bin/panic.sh" "$SB/panic.real"
printf '#!/usr/bin/env bash\necho "panic stand-in: WARNING 1 process(es) from the team are still alive" >&2\nexit 1\n' > "$R/bin/panic.sh"
mkdir -p "$TD"; echo ledger > "$TD/state.md"
out="$(run_env -- reset.sh)"; rc=$?
[ "$rc" != 0 ] && ok "R reset.sh: exits non-zero when panic.sh does (rc $rc)" || no "R reset.sh: exit code after a failed panic" "$out"
[ -f "$TD/state.md" ] && ok "R reset.sh: keeps the run dir when panic.sh reports survivors" || no "R reset.sh: run dir kept" "$out"
/usr/bin/grep -q 'team stopped' <<<"$out" && no "R reset.sh: no 'team stopped' after a failed panic" "$out" || ok "R reset.sh: does not claim 'team stopped'"
/usr/bin/grep -q 'NOT removed' <<<"$out" && ok "R reset.sh: says the run dir was NOT removed" || no "R reset.sh: NOT removed line" "$out"
cp "$SB/panic.real" "$R/bin/panic.sh"
mkdir -p "$TD"; echo ledger > "$TD/state.md"
out="$(run_env -- reset.sh)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TD" ] && ok "R reset.sh: POSITIVE real panic.sh, nothing running: canonical run dir removed, rc 0" || no "R reset.sh: canonical dir removed" "rc=$rc $out"
/usr/bin/grep -q 'team stopped' <<<"$out" && ok "R reset.sh: POSITIVE reports the reset" || no "R reset.sh: reset line" "$out"
mkdir -p "$TD"; echo ledger > "$TD/state.md"
out="$(run_env -- cleanup.sh --force)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TD" ] && ok "R cleanup.sh --force: POSITIVE canonical run dir removed, rc 0" || no "R cleanup.sh: canonical dir removed" "rc=$rc $out"

echo "=== ST: stop-team.sh daemon trees, foreign windows, the orchestrator's line ($SRC) ==="
read -r SESS < <( export TEAM_RUN_ID="$RID"; unset TEAM_DIR TEAM_PORT INTER_SESSION_PORT TEAM_SESSION
                  . "$R/bin/team-env.sh" >/dev/null 2>&1; echo "$TEAM_SESSION" )
[ -n "$SESS" ] || { echo "FATAL: could not derive the sandbox run's TEAM_SESSION" >&2; exit 99; }
mkdir -p "$TD" "$SB/d2/bin"
# The observer's shape (bin/observer.sh): the model call runs in a command substitution, so the tree
# is observer -> subshell -> timeout -> the call. The observer has no TERM trap and dies at once.
printf '#!/usr/bin/env bash\nask(){ out="$(timeout 60 sleep 600 <<<"$1" 2>/dev/null)"; }\nwhile :; do ask x; sleep 5; done\n' > "$SB/d2/bin/observer.sh"
# A daemon that ignores TERM: only the re-check and SIGKILL stop it.
printf '#!/usr/bin/env bash\ntrap "" TERM\nwhile :; do sleep 1; done\n' > "$SB/d2/bin/chrome-supervisor.sh"
OBS="$(start "$RID" bash "$SB/d2/bin/observer.sh")"
DEAF="$(start "$RID" bash "$SB/d2/bin/chrome-supervisor.sh")"
ORCH="$(EXEC_A=claude start "$RID" sleep 600)"     # the orchestrator stop-team leaves running
COMM="$(EXEC_A=claude start "$RID" sleep 600)"     # the communicator, a role stop-team ends
WK="$(EXEC_A=claude start "$RID" sleep 600)"       # a worker
env TEAM_RUN_ID="$RID" TEAM_DIR="$TD" tmux -L "$SOCK" -f /dev/null new-session -d -s "$SESS" -n orchestrator "sleep 600"
OW="$(tmux -L "$SOCK" display-message -p -t "$SESS:orchestrator" '#{window_id}' 2>/dev/null)"
W1="$(tmux -L "$SOCK" new-window -d -t "$SESS" -n w1 -P -F '#{window_id}' "sleep 600" 2>/dev/null)"
tmux -L "$SOCK" new-session -d -s "other-$$" -n foreign "sleep 600"     # another run's session, same socket
FW="$(tmux -L "$SOCK" display-message -p -t "other-$$:foreign" '#{window_id}' 2>/dev/null)"
sleep 0.6
OBS_TREE="$(desc "$OBS")"; for p in $OBS_TREE; do echo "$p" >> "$KIDS"; done
echo "$OBS" > "$TD/observer.pid"; echo "$DEAF" > "$TD/chrome-supervisor.pid"
printf '%s\t%s\torchestrator\n%s\t-\tcommunicator\n%s\t%s\tw1\n999999998\t%s\tghost\n' "$ORCH" "$OW" "$COMM" "$WK" "$W1" "$FW" > "$TD/active"
n="$(printf '%s\n' $OBS_TREE | /usr/bin/grep -c .)"
[ "$n" -ge 3 ] && [ -n "$OW" ] && [ -n "$W1" ] && [ -n "$FW" ] && alive "$DEAF" \
  && ok "ST preconditions: observer tree of $n (subshell, timeout, call), three windows, TERM-deaf daemon alive" \
  || no "ST preconditions" "tree=[$OBS_TREE] ow=$OW w1=$W1 fw=$FW"
# Graceful: the pass that types into each role window runs too.
out="$(env -u TEAM_DIR -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_SESSION TEAM_RUN_ID="$RID" TEAM_TMUX="$SOCK" HOME="$SB/home" \
         bash "$R/bin/stop-team.sh" 2>&1)"; sleep 0.8; show "$out"
alive "$OBS" && no "ST: observer stopped" "" || ok "ST: observer stopped"
left=""; for p in $OBS_TREE; do alive "$p" && left="$left $p:$(ps -o comm= -p "$p")"; done
[ -z "$left" ] && ok "ST: POSITIVE the observer's whole tree (a model call in progress) reaped" || no "ST: observer tree reaped" "alive:$left"
alive "$DEAF" && no "ST: TERM-ignoring daemon SIGKILLed after the re-check" "" || ok "ST: POSITIVE a daemon that ignores TERM is SIGKILLed after the re-check"
windows="$(tmux -L "$SOCK" list-windows -a -F '#{window_id}' 2>/dev/null)"
/usr/bin/grep -qxF "$FW" <<<"$windows" && ok "ST: another session's window named in active is NOT killed" || no "ST: foreign window kept" "$windows"
/usr/bin/grep -q 'stop: teardown' <<<"$(tmux -L "$SOCK" capture-pane -p -t "$FW" 2>/dev/null)" \
  && no "ST: nothing typed into another session's window" "" || ok "ST: nothing typed into another session's window"
/usr/bin/grep -qxF "$W1" <<<"$windows" && no "ST: POSITIVE this run's role window killed" "$windows" || ok "ST: POSITIVE this run's role window killed"
alive "$ORCH" && ok "ST: the orchestrator is left running" || no "ST: orchestrator left running" ""
[ "$(cat "$TD/active" 2>/dev/null)" = "$(printf '%s\t%s\torchestrator' "$ORCH" "$OW")" ] \
  && ok "ST: active keeps exactly the live orchestrator's line" || no "ST: active keeps the orchestrator line" "$(cat "$TD/active" 2>&1)"
/usr/bin/grep -q 'all roles stopped' <<<"$out" && ok "ST: reports all roles stopped" || no "ST: all roles stopped" ""
reset_procs; tmux_kill_unlink tmux "$SOCK"

echo "=== SL: stop-team.sh, a role appended to active while it waited for the roster lock ($SRC) ==="
mkdir -p "$TD"
SL_ROLE="$(EXEC_A=claude start "$RID" sleep 600)"     # recorded in active: stop-team stops it
SL_LATE="$(EXEC_A=claude start "$RID" sleep 600)"     # appended under the lock after stop-team read active
sleep 0.4
printf '%s\t-\tearly1\n' "$SL_ROLE" > "$TD/active"
( flock 9; sleep 6; printf '%s\t-\tlate1\n' "$SL_LATE" >> "$TD/active" ) 9>"$TD/.roster.lock" & SL_HOLD=$!
sleep 0.3
out="$(run_stop)"; wait "$SL_HOLD"; show "$out"
alive "$SL_ROLE" && no "SL: the role recorded in active is stopped" "" || ok "SL: the role recorded in active is stopped"
alive "$SL_LATE" && ok "SL: the role appended during the lock wait is alive (never signalled)" || no "SL: late role alive" ""
[ "$(awk -F'\t' '$3=="late1"' "$TD/active" 2>/dev/null | wc -l)" = 1 ] && ok "SL: active keeps the live appended role's line" || no "SL: appended line kept" "$(cat "$TD/active" 2>&1)"
[ "$(awk -F'\t' '$3=="early1"' "$TD/active" 2>/dev/null | wc -l)" = 0 ] && ok "SL: the stopped role's line is dropped" || no "SL: stopped line dropped" "$(cat "$TD/active" 2>&1)"
reset_procs

echo "=== OT: panic.sh and cleanup.sh --force, the observer's whole tree ($SRC) ==="
# The observer has no TERM trap: it dies at once, its subtree is re-parented, and a pkill -P after the
# TERM finds nothing. The tree must be captured before the TERM, as stop-team.sh does (ST above).
for s in panic.sh cleanup.sh; do
  mkdir -p "$TD"
  OBS="$(start "$RID" bash "$SB/d2/bin/observer.sh")"; sleep 0.6
  OBS_TREE="$(desc "$OBS")"; for p in $OBS_TREE; do echo "$p" >> "$KIDS"; done
  echo "$OBS" > "$TD/observer.pid"
  n="$(printf '%s\n' $OBS_TREE | /usr/bin/grep -c .)"
  [ "$n" -ge 3 ] && ok "OT $s preconditions: observer tree of $n (subshell, timeout, call)" || no "OT $s preconditions" "tree=[$OBS_TREE]"
  a=(); [ "$s" = cleanup.sh ] && a=(--force)
  out="$(run_env -- "$s" "${a[@]}")"; sleep 0.8; show "$out"
  alive "$OBS" && no "OT $s: observer stopped" "" || ok "OT $s: observer stopped"
  left=""; for p in $OBS_TREE; do alive "$p" && left="$left $p:$(ps -o comm= -p "$p")"; done
  [ -z "$left" ] && ok "OT $s: POSITIVE the observer's whole tree (a model call in progress) reaped" || no "OT $s: observer tree reaped" "alive:$left"
  reset_procs
done

echo "=== result: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]

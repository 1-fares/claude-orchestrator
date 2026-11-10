#!/usr/bin/env bash
# bin/inbox.sh and bin/approve.sh: every tmux call goes to the team socket ($TEAM_TMUX), never a
# hard-coded `-L orchestrator`; inbox.sh shows each run's OWN last orchestrator message (the bus log
# is shared by every bus on the machine) and reads that log once, not once per row.
#
# Runs a COPY of the two scripts plus team-env.sh in a scratch clone, so the clone's real .team-*
# dirs are never read, with a stand-in tmux (records its argv, answers from FAKE_TMUX_SESSIONS) and
# a private INTER_SESSION_DATA_DIR. No tmux server, bus or network is touched. The scratch path is
# fixed, like the rest of the suite this test is not meant to run twice at once.
# INBOX_APPROVE_SRC overrides the tree the scripts are copied from (red-first runs on an old build).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${INBOX_APPROVE_SRC:-$repo}"
pass=0 fail=0
ok() { printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
printf 'inbox-approve-socket: starting\n'

rm -rf /tmp/orch-test-inbox-approve
mkdir /tmp/orch-test-inbox-approve || { no "scratch dir exists and cannot be replaced"; exit 1; }
trap 'rm -rf /tmp/orch-test-inbox-approve' EXIT
S=/tmp/orch-test-inbox-approve
mkdir -p "$S/repo/bin/lib" "$S/fakebin" "$S/isdata/clients"
for f in bin/inbox.sh bin/approve.sh bin/team-env.sh bin/lib/tmux-submit.sh bin/lib/tmux-input.sh; do
  cp "$SRC/$f" "$S/repo/$f" || { no "copy $f"; exit 1; }
done
R="$(cd "$S/repo" && pwd)"
REAL_PY="$(command -v python3)"

cat > "$S/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_TMUX_CALLS"
while [ $# -gt 0 ]; do case "$1" in -L|-f|-S) shift 2 ;; *) break ;; esac; done
cmd="${1:-}"; [ $# -gt 0 ] && shift
fmt=""; t=""
while [ $# -gt 0 ]; do case "$1" in -F) fmt="$2"; shift 2 ;; -t) t="$2"; shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  list-sessions) for s in $FAKE_TMUX_SESSIONS; do printf '%s\n' "${fmt//'#{session_name}'/$s}"; done ;;
  has-session) case " $FAKE_TMUX_SESSIONS " in *" ${t%%:*} "*) exit 0 ;; *) exit 1 ;; esac ;;
  display-message) date +%s ;;
  list-windows) echo orchestrator ;;
  *) exit 1 ;;
esac
SH
printf '%s\n' '#!/usr/bin/env bash' 'printf "x\n" >> "$FAKE_PY_CALLS"' 'exec "$REAL_PY" "$@"' > "$S/fakebin/python3"
chmod +x "$S/fakebin/tmux" "$S/fakebin/python3"

# Two runs in the scratch clone; session name and bus port by team-env.sh's derivation.
sess_of() { local h; h="$(printf '%s\0%s' "$R" "$1" | cksum | cut -d' ' -f1)"; echo "orch-${h: -5}"; }
port_of() { local h; h="$(printf '%s\0%s' "$R" "$1" | cksum | cut -d' ' -f1)"; echo $((9500 + h % 400)); }
SA="$(sess_of runa)"; SB="$(sess_of runb)"; PA="$(port_of runa)"; PB="$(port_of runb)"
[ "$PA" != "$PB" ] && ok "PRECONDITION: runa $SA port $PA, runb $SB port $PB" || { no "PRECONDITION: port clash $PA"; exit 1; }
mkdir -p "$R/.team-runa" "$R/.team-runb"

# Listener state files (session id -> port) and a shared bus log with messages from three buses.
printf '{"session_id": "sid-a-orch", "name": "orchestrator", "port": %s}\n' "$PA" > "$S/isdata/clients/101.session"
printf '{"session_id": "sid-a-impl", "name": "impl", "port": %s}\n' "$PA" > "$S/isdata/clients/102.session"
printf '{"session_id": "sid-b-orch", "name": "orchestrator", "port": %s}\n' "$PB" > "$S/isdata/clients/103.session"
printf '{"session_id": "sid-c-orch", "name": "orchestrator", "port": 9999}\n' > "$S/isdata/clients/104.session"
m() { printf '{"ts": "%s", "msg_id": "%s", "kind": "direct", "from": "%s", "from_name": "%s", "from_label": "", "to": "x", "to_session_id": "%s", "text": "%s"}\n' "$@"; }
{
  m 2026-11-10T06:00:00+00:00 m1 sid-a-orch orchestrator sid-a-impl "run A first"
  m 2026-11-10T06:01:00+00:00 m2 sid-b-orch orchestrator sid-b-impl "run B says hello"
  m 2026-11-10T06:02:00+00:00 m3 sid-a-gone orchestrator sid-a-impl "run A after a restart"
  m 2026-11-10T06:03:00+00:00 m4 sid-c-orch orchestrator sid-c-x "another bus entirely"
  m 2026-11-10T06:04:00+00:00 m5 sid-a-impl impl sid-a-orch "not from the orchestrator"
} > "$S/isdata/messages.log"

TT="tt-inbox-$$"
run() {  # run <script> [args]: the copy, on the stand-in tmux, with no inherited team identity
  : > "$S/tmux.calls"; : > "$S/py.calls"
  env -u TEAM_RUN_ID -u TEAM_DIR -u TEAM_SESSION -u TEAM_PORT -u INTER_SESSION_PORT -u TEAM_DIR_ALLOW_OVERRIDE \
    PATH="$S/fakebin:$PATH" REAL_PY="$REAL_PY" TEAM_TMUX="$TT" FAKE_TMUX_SESSIONS="$SA $SB" \
    FAKE_TMUX_CALLS="$S/tmux.calls" FAKE_PY_CALLS="$S/py.calls" INTER_SESSION_DATA_DIR="$S/isdata" \
    bash "$R/bin/$1" "${@:2}" 2>&1
}
socket_ok() {  # every recorded call starts with -L $TT and none names the orchestrator socket
  [ -s "$S/tmux.calls" ] && ! grep -q -- '-L orchestrator' "$S/tmux.calls" \
    && [ "$(grep -vc -- "^-L $TT " "$S/tmux.calls")" = 0 ]
}

# 1 inbox.sh table: each row shows its own run's last orchestrator message
out="$(run inbox.sh)"; rc=$?
rowa="$(grep "^$SA " <<<"$out")"; rowb="$(grep "^$SB " <<<"$out")"
[ $rc -eq 0 ] && [[ "$rowa" == *"run A after a restart"* ]] && [[ "$rowb" == *"run B says hello"* ]] \
  && ok "1 each row shows its own run's last orchestrator message" || no "1 rc=$rc: $out"
! grep -q 'another bus entirely' <<<"$out" && ok "1 a message from another bus is shown for no run" || no "1 foreign message shown: $out"
[ "$(wc -l < "$S/py.calls")" = 1 ] && ok "1 the bus log is read once for 2 rows" || no "1 python ran $(wc -l < "$S/py.calls") times"
socket_ok && ok "1 every tmux call on -L $TT" || no "1 tmux calls: $(cat "$S/tmux.calls")"

# 2 inbox.sh --json: same attribution
out="$(run inbox.sh --json)"; rc=$?
[ $rc -eq 0 ] && "$REAL_PY" -c '
import json, sys
rows = {r["run_id"]: r["last_orchestrator"] for r in json.loads(sys.stdin.read())}
sys.exit(0 if rows["runa"].startswith("run A after a restart") and rows["runb"].startswith("run B says hello") else 1)' <<<"$out" \
  && ok "2 --json carries each run's own message" || no "2 rc=$rc: $out"
socket_ok && ok "2 every tmux call on -L $TT" || no "2 tmux calls: $(cat "$S/tmux.calls")"

# 3 approve.sh --list, and a session that does not exist on the team socket
out="$(run approve.sh --list)"; rc=$?
[ $rc -eq 0 ] && grep -qx "$SA" <<<"$out" && grep -qx "$SB" <<<"$out" && socket_ok \
  && ok "3 approve --list lists the team socket's sessions" || no "3 rc=$rc: $out :: $(cat "$S/tmux.calls")"
out="$(run approve.sh --session orch-nope 'go')"; rc=$?
[ $rc -eq 1 ] && [[ "$out" == *"no such session: 'orch-nope' on socket '$TT'"* ]] && socket_ok \
  && ok "3 approve to a missing session: exit 1, checked on -L $TT" || no "3 missing rc=$rc: $out"

# 4 approve.sh to a live session: the window lookup and the submit go to the team socket (the stand-in
#   has no pane to type into, so the submit itself fails; only the socket is under test here)
out="$(run approve.sh --session "$SA" 'go')"; rc=$?
grep -q 'list-windows' "$S/tmux.calls" && socket_ok \
  && ok "4 approve's window lookup and submit on -L $TT (rc $rc)" || no "4 tmux calls: $(cat "$S/tmux.calls")"

printf 'inbox-approve-socket: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

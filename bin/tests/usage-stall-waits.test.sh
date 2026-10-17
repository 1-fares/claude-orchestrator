#!/usr/bin/env bash
# The usage wall is WAITED OUT, never bought through and never hammered.
#
# This is the policy H9 recorded (one subscription: a usage/session limit is a
# wall to wait for, never a paid option). The two tests that held it,
# api-watchdog-session-limit and api-watchdog-credits-wall, asserted marker
# NAMES of the CF1 handlers that a9b61ba replaced on 2026-07-10 with the generic
# USAGE-STALL path, and were retired by the hive on 2026-10-07. This test holds
# the policy against the path that runs today:
#   1. a pane on the usage-limit dialog is classified stalled-usage;
#   2. the dialog is dismissed with Escape only: never Down, never Enter on the
#      menu, never an option digit (2 = add funds, 3 = switch plan);
#   3. the resume nudge is paced at USAGE_RETRY_SEC: none inside the cadence,
#      exactly one more once it has elapsed (positive control);
#   4. the operator is pushed ONCE, on entry, however many retries follow.
#
# Runs the REAL api-watchdog --once against a fake `tmux` that serves the pane
# and logs every send-keys call. Pushes go to NOTIFY_SINK, a file counted here.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RID="usagewait$$"
TD="$repo/.team-$RID"          # team-env derives TEAM_DIR from TEAM_RUN_ID
FAKEBIN="$(mktemp -d)"
PANEFILE="$(mktemp)"
SENDLOG="$(mktemp)"
SINK="$(mktemp)"
trap 'rm -rf "$TD" "$FAKEBIN" "$PANEFILE" "$SENDLOG" "$SINK" "$SINK".* "${PANE_USAGE:-}" "${PANE_CREDITS:-}"' EXIT

cat > "$FAKEBIN/tmux" <<FAKE
#!/usr/bin/env bash
while [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-f" ]; do shift 2; done
cmd="\${1:-}"; shift || true
case "\$cmd" in
  has-session) exit 0 ;;
  display-message) echo "\${FAKE_PANE_PID:-1}" ;;
  list-sessions) echo "orch-sess" ;;
  list-windows) printf '%s\t%s\n' '@1' 'testrole' ;;
  capture-pane) cat "$PANEFILE" ;;
  send-keys) printf '%s\n' "\$*" >> "$SENDLOG" ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

# Two dialogs, both seen live: the usage-limit dialog that parked the team on
# 2026-07-10, and the "Out of usage credits" dialog that held a role ~7h on
# 2026-07-06 after the credits had already reset (the retired credits-wall test).
PANE_USAGE="$(mktemp)"; PANE_CREDITS="$(mktemp)"
cat > "$PANE_USAGE" <<'PANE'
● Drafting the next section now.
  You have reached your usage limit.
 ❯ 1. Stop and wait for limit to reset
   2. Add funds to continue with usage credits
   3. Switch to Team plan
 Enter to confirm · Esc to cancel
PANE
cat > "$PANE_CREDITS" <<'PANE'
   Out of usage credits
   You've used all of your available usage credits.
   ❯ 1. $0.00 balance · auto-reload off
     2. Buy more credits
     3. Turn on auto-reload
     4. Switch to a subscription plan
   Enter to confirm · Esc to cancel
PANE

# A scan is given SCAN_TIMEOUT (180s). It normally takes 1-3s; the ceiling only
# exists so a wedged scan cannot hang the suite. A scan killed by it is reported,
# because every assertion after it would otherwise read a state nobody wrote.
CADENCE=8   # wide enough that one --once scan (1-3 s here) never spans it
run_once() {
  # NOTIFY_LOG/NOTIFY_STATE_DIR pinned: tests-run exports its own, which would take the
  # decision log away from $SINK.log and share dedupe state across scenarios.
  # NTFY_URL non-empty on purpose: team-env.sh's ${NTFY_URL:-...} treats empty as unset.
  # TEAM_DIR unset: team-env refuses to override a pre-set one (the live run dir in an
  # interactive shell, a scratch dir under tests-run); the run dir comes from RID only.
  env -u TEAM_DIR PATH="$FAKEBIN:$PATH" TEAM_RUN_ID="$RID" USAGE_RETRY_SEC="$CADENCE" \
    NOTIFY_SINK="$SINK" NOTIFY_LOG="$SINK.log" NOTIFY_STATE_DIR="$SINK.state" WATCH_ALERT_SINK=/dev/null NTFY_URL='http://127.0.0.1:9/lsb-blackhole' \
    timeout "${SCAN_TIMEOUT:-180}" bash "${WATCHDOG:-$repo/bin/api-watchdog.sh}" --once >/dev/null 2>&1 || true
}

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

scenario() {
  label="$1"
  rm -rf "$TD"; : > "$SENDLOG"; rm -rf "$SINK".*; : > "$SINK"; cp "$2" "$PANEFILE"
  hf="$TD/health/testrole.json"
  af="$TD/audit/api-watchdog/testrole.log"
  retries() { jq -r '.retries // "?"' "$hf" 2>/dev/null; }
  # notify decisions land in ${NOTIFY_SINK}.log (one line per decision, pushed or filed);
  # real phone pushes land in $NOTIFY_SINK. The usage wall is class info: filed in the
  # digest, never pushed (RULES IN FORCE 1, 2026-09-19).
  pushes()  { grep -c 'hit the usage limit' "$SINK.log" 2>/dev/null || true; }
  phone()   { grep -c . "$SINK" 2>/dev/null || true; }
  nudges()  { grep -ciF 'try again' "$SENDLOG" 2>/dev/null || true; }

  # Scan 1: entry.
  run_once
  st="$(jq -r '.state // "?"' "$hf" 2>/dev/null)"
  [ "$st" = "stalled-usage" ] && ok "$label: classified stalled-usage" || bad "$label: state '$st' (want stalled-usage)"
  [ "$(retries)" = "1" ] && ok "$label: one resume nudge on entry (retries=1)" || bad "$label: retries '$(retries)' after entry (want 1)"
  grep -qw 'Escape' "$SENDLOG" && ok "$label: dialog dismissed with Escape" || bad "$label: no Escape sent"
  [ "$(pushes)" = "1" ] && ok "$label: operator notified once on entry (one notify decision)" || bad "$label: notify decisions after entry: $(pushes) (want 1)"

  # Scan 2: inside the cadence. Nothing new may be sent, nothing pushed.
  n_before="$(nudges)"
  run_once
  [ "$(retries)" = "1" ] && ok "$label: no retry inside USAGE_RETRY_SEC" || bad "$label: retries '$(retries)' inside the cadence (want 1)"
  [ "$(nudges)" = "$n_before" ] && ok "$label: no keys typed inside the cadence" || bad "$label: nudge typed inside the cadence"
  [ "$(pushes)" = "1" ] && ok "$label: no second push inside the cadence" || bad "$label: pushes: $(pushes) (want 1)"

  # Scan 3: cadence elapsed. Exactly one more retry (positive control), still one push.
  sleep $((CADENCE + 1))
  run_once
  [ "$(retries)" = "2" ] && ok "$label: retried once the cadence elapsed (retries=2)" || bad "$label: retries '$(retries)' after the cadence (want 2)"
  [ "$(pushes)" = "1" ] && ok "$label: still one push after a retry" || bad "$label: pushes: $(pushes) after a retry (want 1)"
  grep -q 'usage-retry 2 (cadence' "$af" 2>/dev/null && ok "$label: audit: usage-retry 2 logged" || bad "$label: audit missing usage-retry 2"
  [ "$(phone)" = "0" ] && ok "$label: nothing pushed to the phone (info is filed)" || bad "$label: phone pushes: $(phone) (want 0; a usage wall is info)"
  grep -q 'DIGEST info' "$SINK.log" 2>/dev/null && ok "$label: the one decision is DIGEST info" || bad "$label: decision is not DIGEST info: $(head -1 "$SINK.log" 2>/dev/null)"

  # Never toward a paid option, in any scan. The nudge itself is typed text followed
  # by Enter (tmux_submit), sent AFTER Escape has closed the menu; so every Enter must
  # follow a typed (-l) line, and every retry must open with Escape. An Enter or a
  # Down with the menu still up is what would confirm or move to a paid option.
  if grep -qwE 'Down|Up' "$SENDLOG"; then bad "$label: moved in the menu: $(grep -wE 'Down|Up' "$SENDLOG" | head -1)"; else ok "$label: never moved in the menu (no Down/Up)"; fi
  if grep -qE '(^| )[2-9]$' "$SENDLOG"; then bad "$label: sent an option digit (2+ = paid)"; else ok "$label: never sent an option digit"; fi
  order="$(awk '
    / Escape$/ { menu = 0; typed = 0; next }
    / -l /     { if (menu) { print "typed into the open menu: " $0; exit } typed = 1; next }
    / Enter$/  { if (!typed) { print "Enter with no typed nudge before it: " NR; exit } next }
  ' menu=1 "$SENDLOG")"
  [ -z "$order" ] && ok "$label: Escape first; every Enter submits the typed nudge" || bad "$label: $order"
  [ "$(grep -cw 'Escape' "$SENDLOG")" = "2" ] && ok "$label: one Escape per retry (2 retries)" || bad "$label: Escape count $(grep -cw 'Escape' "$SENDLOG") (want 2)"
}

scenario usage-limit "$PANE_USAGE"
# The out-of-credits pane is deliberately NOT a scenario here: this engine
# classifies it as awaiting-input, not stalled-usage, so it exercises a
# different path. A deployment whose detection treats it as a usage wall can add
# `scenario credits "$PANE_CREDITS"`.

# False positive: a WORKING role with the credits wording on screen (quoting a log,
# a diff of this change, a bus line) and no modal. It must get no Escape and no typed
# nudge. A bare phrase match in USAGE_RE fails this; the affordance guard passes it.
label=quoted
rm -rf "$TD"; : > "$SENDLOG"; rm -rf "$SINK".*; : > "$SINK"
cat > "$PANEFILE" <<'PANE'
● The 07-06 wedge: the pane showed "Out of usage credits" and "You've used all of
  your available usage credits." with options 2-4 being paid. Reading the classifier now.
● Read(bin/lib/watchdog-detect.sh)
  ⎿  Read 140 lines
────────────────────────────────────────────────
❯
────────────────────────────────────────────────
  ⏵⏵ bypass permissions on · 1 monitor
PANE
run_once
st="$(jq -r '.state // "?"' "$hf" 2>/dev/null)"
[ "$st" != "stalled-usage" ] && ok "$label: quoted wording is not a usage stall (state '$st')" || bad "$label: quoted wording classified stalled-usage"
[ ! -s "$SENDLOG" ] && ok "$label: no keys sent to a working role" || bad "$label: keys sent to a working role: $(head -2 "$SENDLOG" | tr '\n' ' ')"

# --- a MULTI-DAY wall is paced on its own reset, and it pages -----------------
# The flat cadence suits the 5-hour session limit, which clears inside a shift.
# The seven-day limit does not clear until the account resets or the operator
# switches account, so hammering it files refused calls for days (2026-10-17: 67
# in 76 minutes across six roles). When the role's refusal record names the kind
# and the reset, the cadence becomes USAGE_WALL_PROBE_SEC and the operator is
# PAGED, because only they can clear it.
label="seven-day wall"
rm -rf "$TD"; : > "$SENDLOG"; rm -rf "$SINK".*; : > "$SINK"; cp "$PANE_USAGE" "$PANEFILE"
hf="$TD/health/testrole.json"; af="$TD/audit/api-watchdog/testrole.log"
SESSD="$(mktemp -d)"; PROJD="$(mktemp -d)"; trap 'rm -rf "$TD" "$FAKEBIN" "$PANEFILE" "$SENDLOG" "$SINK" "$SINK".* "$SESSD" "$PROJD" "${PANE_USAGE:-}" "${PANE_CREDITS:-}"' EXIT
FAKE_PANE_PID=4242; SID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
printf '{"sessionId": "%s", "cwd": "%s"}\n' "$SID" "$HOME/project" > "$SESSD/$FAKE_PANE_PID.json"
wall_once() { # wall_once <resetsAt-epoch>
  printf '{"type":"user","isApiErrorMessage":true,"apiErrorStatus":429,"quotaLimits":{"status":"rejected","resetsAt":%s,"rateLimitType":"seven_day"}}\n' "$1" > "$PROJD/$SID.jsonl"
  env -u TEAM_DIR PATH="$FAKEBIN:$PATH" TEAM_RUN_ID="$RID" USAGE_RETRY_SEC="$CADENCE" \
    USAGE_WALL_PROBE_SEC=86400 USAGE_WALL_PAGE_SEC=7200 \
    FAKE_PANE_PID="$FAKE_PANE_PID" WATCHDOG_SESSIONS_DIR="$SESSD" COMPACT_PROJECT_DIR="$PROJD" \
    NOTIFY_SINK="$SINK" NOTIFY_LOG="$SINK.log" NOTIFY_STATE_DIR="$SINK.state" WATCH_ALERT_SINK=/dev/null NTFY_URL='http://127.0.0.1:9/lsb-blackhole' \
    timeout "${SCAN_TIMEOUT:-180}" bash "${WATCHDOG:-$repo/bin/api-watchdog.sh}" --once >/dev/null 2>&1 || true
}
echo "$label: reset two days out"
wall_once "$(( $(date +%s) + 172800 ))"
[ "$(jq -r '.state // "?"' "$hf" 2>/dev/null)" = "stalled-usage" ] && ok "$label: classified stalled-usage" || bad "$label: not stalled-usage"
grep -q 'USAGE-WALL (seven_day;' "$af" 2>/dev/null && ok "$label: audit names the wall kind and reset" || bad "$label: no USAGE-WALL line: $(tail -2 "$af" 2>/dev/null)"
[ -s "$TD/health/testrole.usage-wall" ] && ok "$label: wall marker written" || bad "$label: no wall marker"
[ "$(grep -c . "$SINK" 2>/dev/null || echo 0)" -ge 1 ] && ok "$label: the operator is PAGED (reached the phone)" || bad "$label: nothing reached the phone; a multi-day wall must page"
grep -qi 'login' "$SINK" 2>/dev/null && ok "$label: the page says what the operator must do" || bad "$label: page does not name the action: $(head -1 "$SINK" 2>/dev/null)"
n1="$(jq -r '.retries // 0' "$hf" 2>/dev/null)"
echo "$label: past USAGE_RETRY_SEC but far inside the probe cadence"
sleep $((CADENCE + 1))
wall_once "$(( $(date +%s) + 172800 ))"
[ "$(jq -r '.retries // 0' "$hf" 2>/dev/null)" = "$n1" ] && ok "$label: no retry on the 300s cadence (the storm is gone)" || bad "$label: retried on the short cadence: $n1 -> $(jq -r '.retries // 0' "$hf")"
# The marker carries the reset recorded on entry; a real reset never moves
# earlier, so it expires by wall clock, not by the transcript changing.
echo "$label: the recorded reset passes"
printf 'seven_day %s\n' "$(( $(date +%s) - 60 ))" > "$TD/health/testrole.usage-wall"
wall_once "$(( $(date +%s) + 172800 ))"
[ ! -e "$TD/health/testrole.usage-wall" ] && ok "$label: marker dropped once its reset passed" || bad "$label: marker survived its own reset"
[ "$(jq -r '.retries // 0' "$hf" 2>/dev/null)" -gt "$n1" ] && ok "$label: ordinary cadence resumed (positive control)" || bad "$label: no retry after the reset passed"

# The other way out is the operator switching account: the role leaves the
# dialog, and the marker must not outlive the wall it described.
echo "$label: the operator switches account and the role works again"
cat > "$PANEFILE" <<'PANE2'
  Running a check
❯
  ⏵⏵ bypass permissions on
PANE2
printf 'seven_day %s\n' "$(( $(date +%s) + 172800 ))" > "$TD/health/testrole.usage-wall"
wall_once "$(( $(date +%s) + 172800 ))"
[ ! -e "$TD/health/testrole.usage-wall" ] && ok "$label: marker dropped when the role left the dialog" || bad "$label: marker outlived the wall after recovery"

echo
if [ "$fail" = 0 ]; then echo "usage-stall-waits.test: PASS"; exit 0
else echo "usage-stall-waits.test: FAIL"; echo "--- send-keys log:"; cat "$SENDLOG"; exit 1; fi

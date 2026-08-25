#!/usr/bin/env bash
# The permission-mode watchdog must restore a drifted pane WITHOUT ever
# confirming a prompt it does not understand.
#
# 2026-08-25: the orchestrator sat ~30m on the auto-mode classifier gate for a
# `gh pr merge` into dev. Fares got the phone escalations and could not act on
# them, because answering a tmux selection menu needs a laptop. The pane had
# silently drifted from "bypass permissions on" to "auto mode on" at some point
# after launch, despite being spawned with --dangerously-skip-permissions; in
# bypass the classifier gate never arms, so holding the mode removes the whole
# class of prompt.
#
# The dangerous failure mode of a fix like this is obvious and must be tested
# for directly: a daemon that presses keys to clear prompts can press "Yes" on
# something destructive. Hence cases 3, 4 and 5 below, which assert on what is
# NOT sent.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ ! -r "$repo/bin/tests/lib/isolate.sh" ]; then
  echo "FATAL: isolate.sh missing; this test's cleanup removes \$TEAM_DIR" >&2; exit 1
fi
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/isolate.sh"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh" >/dev/null 2>&1 || true
command -v isolate_assert >/dev/null 2>&1 || { echo "FATAL: isolate_assert undefined" >&2; exit 99; }
isolate_assert

PMW="${PMW_SCRIPT:-$repo/bin/permission-mode-watchdog.sh}"
[ -x "$PMW" ] || { echo "FATAL: $PMW missing or not executable" >&2; exit 1; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH:?}" "${TEAM_DIR:?}"' EXIT
FAKEBIN="$SCRATCH/bin"; mkdir -p "$FAKEBIN" "$TEAM_DIR/health"
PANEFILE="$SCRATCH/pane"; SENDLOG="$SCRATCH/sendkeys"; FLIPFILE="$SCRATCH/flips_on_btab"

BYPASS='  -- INSERT -- ⏵⏵ bypass permissions on · 1 monitor'
AUTO='  -- INSERT -- ⏵⏵ auto mode on · 1 monitor'

# Fake tmux: records every send-keys. If FLIPFILE exists, a BTab rewrites the
# pane to the bypass status line -- a mode that cycles back. Without it the
# drift survives, which is the "restore failed" shape.
cat > "$FAKEBIN/tmux" <<FAKE
#!/usr/bin/env bash
while [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-f" ]; do shift 2; done
cmd="\${1:-}"; shift || true
case "\$cmd" in
  has-session)  exit 0 ;;
  list-windows) printf '%s\t%s\n' '0' 'orchestrator' ;;
  capture-pane) cat "$PANEFILE" ;;
  send-keys)
    printf '%s\n' "\$*" >> "$SENDLOG"
    case "\$*" in
      *BTab*)   [ -f "$FLIPFILE" ] && printf '%s\n' "$BYPASS" > "$PANEFILE" ;;
      *Escape*) grep -v 'Do you want to proceed\|Enter to select\|classifier' "$PANEFILE" > "$PANEFILE.t" 2>/dev/null; mv "$PANEFILE.t" "$PANEFILE" ;;
    esac ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"

run_sweep() {
  : > "$SENDLOG"
  env PATH="$FAKEBIN:$PATH" PMW_ONESHOT=1 PMW_SETTLE=0 PMW_MAX_PRESSES=4 \
      PMW_SOCKET=testsock PMW_SESSION=testsess PMW_UNREADABLE_ALARM=4 \
      PMW_LOG="$SCRATCH/pmw.log" NTFY_URL= \
      bash "$PMW" >/dev/null 2>&1
}
sent()     { grep -q -- "$1" "$SENDLOG" 2>/dev/null; }
sent_any() { [ -s "$SENDLOG" ]; }

echo "== 1. pane already in the expected mode: no keystrokes at all"
printf '%s\n' "$BYPASS" > "$PANEFILE"; : > "$FLIPFILE"
run_sweep
if sent_any; then no "quiet when already in bypass" "sent: $(tr '\n' ';' < "$SENDLOG")"
else ok "quiet when already in bypass"; fi

echo "== 2. drifted to auto mode, no prompt open: cycles back with shift+tab"
printf '%s\n' "$AUTO" > "$PANEFILE"; : > "$FLIPFILE"
run_sweep
if sent BTab; then ok "sends shift+tab to restore the mode"
else no "sends shift+tab to restore the mode" "sendlog empty"; fi
if grep -q 'RESTORED' "$SCRATCH/pmw.log" 2>/dev/null; then ok "logs the restoration"
else no "logs the restoration" "no RESTORED line"; fi

echo "== 3. GUARD: drifted AND a real (non-classifier) prompt is open -> hands off"
{ echo "Do you want to proceed?"; echo " 1. Yes"; echo " 3. No"; printf '%s\n' "$AUTO"; } > "$PANEFILE"
: > "$FLIPFILE"
run_sweep
if sent_any; then
  no "never touches a pane with a real prompt open" "sent: $(tr '\n' ';' < "$SENDLOG")"
else ok "never touches a pane with a real prompt open"; fi

echo "== 4. classifier gate: cancels with Escape, never confirms"
{ echo "Auto mode classifier requires confirmation for this command."; \
  echo "Do you want to proceed?"; echo " 1. Yes"; echo " 3. No"; printf '%s\n' "$AUTO"; } > "$PANEFILE"
: > "$FLIPFILE"
run_sweep
if sent Escape; then ok "cancels the classifier gate with Escape"
else no "cancels the classifier gate with Escape" "sent: $(tr '\n' ';' < "$SENDLOG")"; fi
# The whole safety case: Escape refuses, Enter/1/y would confirm.
if grep -qE '(^|[^a-zA-Z])(Enter|1|2|y|Yes)([^a-zA-Z]|$)' "$SENDLOG" 2>/dev/null; then
  no "never sends a confirming keystroke" "sent: $(tr '\n' ';' < "$SENDLOG")"
else ok "never sends a confirming keystroke"; fi

echo "== 5. restore fails: writes a durable marker instead of failing silently"
printf '%s\n' "$AUTO" > "$PANEFILE"; rm -f "$FLIPFILE"
run_sweep
if [ -f "$TEAM_DIR/health/permission-mode-orchestrator.md" ]; then
  ok "writes the stuck marker when cycling does not help"
else no "writes the stuck marker when cycling does not help" "no marker in $TEAM_DIR/health"; fi
n="$(grep -c BTab "$SENDLOG" 2>/dev/null || echo 0)"
if [ "$n" -le 4 ]; then ok "bounded at PMW_MAX_PRESSES presses ($n)"
else no "bounded at PMW_MAX_PRESSES presses" "pressed $n times"; fi

echo "== 5b. GUARD: mode unreadable -> never cycles blind"
printf '%s\n' '  -- INSERT -- (no mode marker rendered)' > "$PANEFILE"; rm -f "$FLIPFILE"
rm -f "$TEAM_DIR/health/permission-mode-orchestrator.md" "$TEAM_DIR/health/.pmw-unreadable-orchestrator"
run_sweep
if sent_any; then
  no "never cycles a mode it cannot read" "sent: $(tr '\n' ';' < "$SENDLOG")"
else ok "never cycles a mode it cannot read"; fi

echo "== 5c. persistent unreadability is reported, not silently tolerated"
for _ in 1 2 3; do run_sweep; done
if [ -f "$TEAM_DIR/health/permission-mode-orchestrator.md" ]; then
  ok "alarms after PMW_UNREADABLE_ALARM sweeps"
else no "alarms after PMW_UNREADABLE_ALARM sweeps" "no marker written"; fi

echo "== 6. recovery clears the marker"
printf '%s\n' "$BYPASS" > "$PANEFILE"
run_sweep
if [ -f "$TEAM_DIR/health/permission-mode-orchestrator.md" ]; then
  no "clears the marker once the mode is back" "marker still present"
else ok "clears the marker once the mode is back"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# The pane detectors in bin/lib/watchdog-detect.sh must not lose a MATCH to
# pipefail. api-watchdog runs with `set -o pipefail`; in `... | tail | grep -q`
# grep exits on its first match, and if tail is still writing it takes SIGPIPE,
# so the pipeline returns 141 and the match reads as a NON-MATCH. On a real pane
# this happened in 3 of 2000 classifications of the usage dialog (read as
# awaiting-input). Here the race is made certain: `tail` is replaced by a
# function that prints the real tail and then 256 KB of blank lines, which no
# pipe can hold, so a `tail | grep -q` always loses its match, while a tail read
# into a variable loses only the trailing blank lines.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/lib/watchdog-detect.sh"
pattern_regex="$(grep -vE '^[[:space:]]*(#|$)' "$repo/bin/api-watchdog.patterns" | paste -sd'|' -)"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

# (Written straight to the pipe: held in a variable, the blank lines would be
# stripped by the command substitution, and the shim would add nothing.)
tail() { command tail "$@"; head -c 262144 /dev/zero | tr '\0' '\n'; }

usage_pane=$'● Drafting the next section now.\n  You have reached your usage limit.\n ❯ 1. Stop and wait for limit to reset\n   2. Add funds to continue with usage credits\n   3. Switch to Team plan\n Enter to confirm · Esc to cancel'
await_pane=$'● Bash(rm -r build)\n  Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Enter to confirm · Esc to cancel'
busy_pane=$'● Reading the logs.\n· Working… (12s · esc to interrupt)\n❯ '

# Positive control: the shim really makes `tail | grep -q` lose its match.
if printf 'x\n' | tail -1 | grep -q x; then bad "control: the tail shim did not break a piped grep -q (the test would prove nothing)"
else ok "control: under the shim, printf | tail | grep -q loses its match"; fi

s="$(printf '%s' "$usage_pane" | _classify_text)"
[ "$s" = stalled-usage ] && ok "usage dialog classifies stalled-usage" || bad "usage dialog classified '$s' (want stalled-usage)"
s="$(printf '%s' "$await_pane" | _classify_text)"
[ "$s" = awaiting-input ] && ok "confirmation prompt classifies awaiting-input" || bad "confirmation prompt classified '$s' (want awaiting-input)"
printf '%s' "$usage_pane" | _is_usage_stall_text && ok "_is_usage_stall_text matches the usage dialog" || bad "_is_usage_stall_text lost its match"
printf '%s' "$await_pane" | _is_awaiting_input_text && ok "_is_awaiting_input_text matches the prompt" || bad "_is_awaiting_input_text lost its match"
printf '%s' "$usage_pane" | _has_modal_dialog_text && ok "_has_modal_dialog_text matches the dialog footer" || bad "_has_modal_dialog_text lost its match"
printf '%s' "$busy_pane" | _is_busy_text && ok "_is_busy_text matches the spinner" || bad "_is_busy_text lost its match"

echo
if [ "$fail" = 0 ]; then echo "watchdog-detect-pipefail.test: PASS"; exit 0
else echo "watchdog-detect-pipefail.test: FAIL"; exit 1; fi

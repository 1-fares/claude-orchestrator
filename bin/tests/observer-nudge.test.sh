#!/usr/bin/env bash
# bin/lib/observer-nudge.sh: an observer nudge is a full orchestrator turn, so a
# repeat must be silent. Pure-bash test, no tmux, no model.
#
# Measured case this guards (downstream fork, 2026-09-01/02): on unchanged facts
# the model alternated flags=issue/none and models=keep/down pass to pass; a
# "nudge when the signature changes" rule fired on nearly every other pass,
# 35 nudges in 30 hours. The re-nudge window must swallow an A/B/A/B oscillation.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
# shellcheck disable=SC1091
. "$repo/bin/lib/observer-nudge.sh"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
ring="$TD/ring"
export OBSERVER_RENUDGE_SEC=3600 OBSERVER_NUDGE_RING=4

# signature extraction
sig="$(printf 'VERDICT: team=Hold models=keep host=ok flags=issue\nHEADLINE: x\n' | _verdict_sig)"
[ "$sig" = "hold|keep|ok|issue" ] && ok "verdict tokens extracted, lower-cased" || bad "sig=$sig"
sig="$(printf '(model call failed)\n' | _verdict_sig)"
[ "$sig" = '?|?|?|?' ] && ok "failed call yields the constant signature" || bad "failed sig=$sig"

A='hold|keep|ok|none'; B='hold|keep|ok|issue'; C='retire|keep|ok|none'
t=1000000
observer_nudge_should "$A" "$t" "$ring" && ok "first verdict nudges" || bad "first verdict silent"
observer_nudge_should "$A" "$((t+900))" "$ring" && bad "identical verdict re-nudged" || ok "identical verdict silent"
observer_nudge_should "$B" "$((t+1800))" "$ring" && ok "a new verdict nudges" || bad "new verdict silent"
observer_nudge_should "$A" "$((t+2700))" "$ring" && bad "A/B/A flap re-nudged inside the window" || ok "A/B/A flap silent inside the window"
observer_nudge_should "$B" "$((t+3600))" "$ring" && bad "B/A/B flap re-nudged inside the window" || ok "B/A/B flap silent inside the window"
observer_nudge_should "$C" "$((t+3700))" "$ring" && ok "a third, genuinely new verdict nudges" || bad "third verdict silent"
observer_nudge_should "$A" "$((t+1000+3600))" "$ring" && ok "A nudges again once its window has passed" || bad "A silent after its window"
observer_nudge_should '?|?|?|?' "$((t+9000))" "$ring" && bad "failed-call signature nudged" || ok "failed-call signature never nudges"
n=$(wc -l < "$ring"); [ "$n" -le 4 ] && ok "ring bounded at OBSERVER_NUDGE_RING ($n lines)" || bad "ring grew to $n lines"

[ "$fail" = 0 ] && echo "observer-nudge.test: PASS" || { echo "observer-nudge.test: FAIL"; exit 1; }

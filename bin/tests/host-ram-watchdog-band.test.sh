#!/usr/bin/env bash
# host-ram-watchdog-band.test.sh: band_for hysteresis of bin/host-ram-watchdog.sh, through its HRW_TEST
# hook (sources the daemon's functions; no lock, pidfile, trap or loop). Pure: no file is written.
# The swap-amplified WARN enters at RAM >= SWAP_AMP_RAM_PCT (70) with swap >= SWAP_HI_PCT (90), below
# RESUME_PCT (75), so the RAM-only hold never covered it: RAM 72/69/71/69 with swap 92 gave
# WARN/CLEAR/WARN/CLEAR. While swap stays high the band now holds at WARN until RAM < SWAP_AMP_RAM_PCT - 5.
# Thresholds are pinned to the defaults so an exported HRW_* in the caller's env cannot move them.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [ "$2" = "$3" ]; then ok "$1 (${2:-CLEAR})"; else no "$1: want [${3:-CLEAR}] got [${2:-CLEAR}]"; fi; }

export HRW_WARN_PCT=85 HRW_FREEZE_PCT=95 HRW_RESUME_PCT=75 HRW_SWAP_HI_PCT=90 HRW_SWAP_AMP_RAM_PCT=70
export NOTIFY_SINK=/dev/null WATCH_ALERT_SINK=/dev/null
# shellcheck disable=SC1091
HRW_TEST=1 . "$repo/bin/host-ram-watchdog.sh" || { echo "  FAIL sourcing host-ram-watchdog.sh under HRW_TEST"; exit 1; }
declare -F band_for >/dev/null || { echo "  FAIL band_for not defined after sourcing"; exit 1; }

echo "== RAM path (unchanged)"
eq "fresh WARN at RAM 86"                       "$(band_for 86 10 "")"    "WARN"
eq "fresh FREEZE at RAM 96"                     "$(band_for 96 0 "")"     "FREEZE"
eq "healthy host, high idle swap (42/89)"       "$(band_for 42 89 "")"    ""
eq "hold WARN in the RAM dead-band (80, was WARN)" "$(band_for 80 0 WARN)" "WARN"
eq "hold FREEZE in the RAM dead-band (80, was FREEZE)" "$(band_for 80 0 FREEZE)" "FREEZE"
eq "clear below RESUME with low swap (70/0, was WARN)" "$(band_for 70 0 WARN)" ""

echo "== swap path"
eq "fresh WARN on RAM 72 + swap 92"             "$(band_for 72 92 "")"    "WARN"
eq "hold WARN at RAM 68 while swap 95"          "$(band_for 68 95 WARN)"  "WARN"
eq "hold boundary: RAM 65 (= 70 - 5) holds"     "$(band_for 65 95 WARN)"  "WARN"
eq "clear at RAM 64 (below 70 - 5)"             "$(band_for 64 95 WARN)"  ""
eq "clear when swap drops below 90 (68/80)"     "$(band_for 68 80 WARN)"  ""
eq "no fresh WARN from the hold zone (68/95, was CLEAR)" "$(band_for 68 95 "")" ""
eq "swap path steps FREEZE down to WARN (68/95)" "$(band_for 68 95 FREEZE)" "WARN"

echo "== the reported sequence: RAM 72/69/71/69/70/68 with swap 92"
b=""; seq=""
for r in 72 69 71 69 70 68; do b="$(band_for "$r" 92 "$b")"; seq="$seq${b:-CLEAR} "; done
eq "no WARN/CLEAR flip" "$seq" "WARN WARN WARN WARN WARN WARN "
b="WARN"; seq=""
for r in 66 64 66; do b="$(band_for "$r" 92 "$b")"; seq="$seq${b:-CLEAR} "; done
eq "release below 65, no re-entry before RAM 70" "$seq" "WARN CLEAR CLEAR "

echo
echo "host-ram-watchdog-band: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]

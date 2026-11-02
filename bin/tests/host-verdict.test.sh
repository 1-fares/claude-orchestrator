#!/usr/bin/env bash
# host-verdict.test.sh: bin/lib/host-verdict.sh on fixed /proc inputs. The verdict follows the 15-minute load per
# core (the 2026-10-29 11:52Z case: 1.08/4.25/5.44 on 4 vCPU is overloaded, not "ok"), states swap use and names
# the top swap holders by process name. The observer prompt carries the line and tells the model to start from it.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
export NOTIFY_SINK="$tmp/notify.log" WATCH_ALERT_SINK="$tmp/alert.log"
# shellcheck source=bin/lib/host-verdict.sh
. "$repo/bin/lib/host-verdict.sh"
pass=0; fail=0
check() { if grep -qF -- "$2" <<<"$3"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s: want "%s" in: %s\n' "$1" "$2" "$3"; fi; }

proc() {   # dir, loadavg, swap_total_kb, swap_free_kb, then name:swap_kb pairs
  local d="$tmp/$1" i=100; shift
  mkdir -p "$d"; echo "$1 0.50 0.40 1/100 1" > "$d/loadavg"
  printf 'MemTotal: 16000000 kB\nMemAvailable: 8000000 kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$2" "$3" > "$d/meminfo"
  shift 3
  for pair in "$@"; do i=$((i+1)); mkdir -p "$d/$i"; printf 'Name:\t%s\nVmSwap:\t%s kB\n' "${pair%%:*}" "${pair##*:}" > "$d/$i/status"; done
  echo "$d"
}

d="$(proc case1152 "1.08 4.25 5.44" 8388608 1593836 chrome:2000000 chrome:1500000 chrome-devtools:900000 node:300000 claude:200000 bash:0)"
out="$(host_verdict "$d" 4)"
check "11:52Z case is overloaded on the 15-min average" "HOST VERDICT: overloaded: 15-min load 5.44 on 4 vCPU = 1.36 per core" "$out"
check "thresholds are stated" "(ok <= 0.70, busy <= 1.00, overloaded above" "$out"
check "1/5-min shown for trend only" "1/5-min 1.08/4.25 for trend only" "$out"
check "swap use stated" "swap 81% of 8.0 GiB used" "$out"
check "top holders by name, summed and counted" "top holders: chrome x2 3.3 GiB, chrome-devtools x1 0.9 GiB, node x1 0.3 GiB" "$out"
grep -q "claude" <<<"$out" && { fail=$((fail+1)); echo "  FAIL only HV_TOP=3 holders listed"; } || { pass=$((pass+1)); echo "  ok   only the top 3 holders listed"; }

check "ok band" "HOST VERDICT: ok: 15-min load 2.00 on 4 vCPU = 0.50 per core" "$(host_verdict "$(proc okc "9.00 3.00 2.00" 8388608 8388608)" 4)"
check "busy band" "HOST VERDICT: busy:" "$(host_verdict "$(proc busyc "0.10 0.20 3.60" 8388608 8388608)" 4)"
check "no swap configured" "swap none configured used" "$(host_verdict "$(proc noswap "1 1 1" 0 0)" 4)"
check "a 1-min spike alone does not overload" "HOST VERDICT: ok:" "$(host_verdict "$(proc spike "12.00 1.00 0.80" 8388608 8388608)" 4)"

grep -qF '$(host_verdict /proc "$ncpu")' "$repo/bin/observer.sh" && { pass=$((pass+1)); echo "  ok   observer prompt carries the verdict line"; } || { fail=$((fail+1)); echo "  FAIL observer prompt line"; }
grep -qF 'Start from the HOST VERDICT line' "$repo/bin/observer.sh" && { pass=$((pass+1)); echo "  ok   observer HOST item points at the verdict"; } || { fail=$((fail+1)); echo "  FAIL observer HOST item"; }
grep -qF '"$repo/bin/lib/host-verdict.sh"' <<<"$(sed -n '/^self_reload_init/,/^$/p' "$repo/bin/observer.sh")" && { pass=$((pass+1)); echo "  ok   observer self-reloads the lib"; } || { fail=$((fail+1)); echo "  FAIL self-reload list"; }

echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ] && echo "ALL PASS"
exit "$fail"

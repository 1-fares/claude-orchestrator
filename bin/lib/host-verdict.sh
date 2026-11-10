#!/usr/bin/env bash
# host-verdict.sh: the observer's HOST verdict, computed here instead of left to the model.
# 2026-10-29 11:52Z the model read load 1.08/4.25/5.44 on 4 vCPU and said "host ok" because
# of the 1-minute 1.08. The verdict reasons from the 15-minute average per core:
#   ok         l15/ncpu <= HV_BUSY (0.70)
#   busy       l15/ncpu <= HV_OVER (1.00)
#   overloaded above that
# and states swap use with the top swap holders by process name (VmSwap summed per Name),
# since a box can be "ok" on load while 39-54 chrome processes hold most of the swap.
: "${HV_BUSY:=0.70}"
: "${HV_OVER:=1.00}"
: "${HV_TOP:=3}"

# host_verdict [proc_root] [ncpu] -> one line on stdout.
host_verdict() {
  local proc="${1:-/proc}" ncpu="${2:-$(nproc)}" l1 l5 l15 per state swap top
  read -r l1 l5 l15 _ < "$proc/loadavg" || { echo "HOST VERDICT: unknown (no $proc/loadavg)"; return 0; }
  per="$(awk -v l="$l15" -v n="$ncpu" 'BEGIN{printf "%.2f", (n>0 ? l/n : 0)}')"
  state="$(awk -v p="$per" -v b="$HV_BUSY" -v o="$HV_OVER" 'BEGIN{print (p<=b ? "ok" : (p<=o ? "busy" : "overloaded"))}')"
  swap="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{ if (t>0) printf "%d%% of %.1f GiB", (100*(t-f)+t-1)/t, t/1048576; else print "none configured" }' "$proc/meminfo" 2>/dev/null)"
  # One awk over the concatenated status files (each starts with Name:), not one awk per
  # process: ~500 forks and 2 s per call on a desktop host. cat skips a vanished pid.
  top="$(printf '%s\0' "$proc"/[0-9]*/status | xargs -0 cat 2>/dev/null \
         | awk '/^Name:/{n=$2} /^VmSwap:/{ if ($2>0) { kb[n]+=$2; c[n]++ } } END{for (n in kb) printf "%d %s %d\n", kb[n], n, c[n]}' \
              | sort -rn | head -n "$HV_TOP" \
              | awk '{printf "%s%s x%d %.1f GiB", (NR>1 ? ", " : ""), $2, $3, $1/1048576}')"
  printf 'HOST VERDICT: %s: 15-min load %s on %s vCPU = %s per core (ok <= %s, busy <= %s, overloaded above; 1/5-min %s/%s for trend only); swap %s used%s\n' \
    "$state" "$l15" "$ncpu" "$per" "$HV_BUSY" "$HV_OVER" "$l1" "$l5" "${swap:-unknown}" "${top:+, top holders: $top}"
}

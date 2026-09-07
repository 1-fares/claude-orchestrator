#!/usr/bin/env bash
# capability-probe.sh <probes.conf> [--list|--only <name>|--no-notify]
#
# Proves, read-only or dry-run, that the team can still perform every privileged action
# its work depends on: cloud reads, command execution on the boxes it manages, package
# registries, the git remotes, the message connectors, the bus, tmux, the model API.
#
# WHY. Every permission change (least-privilege policies, branch protection, sudo rules)
# risks leaving the team unable to work in a way nobody notices until a unit fails hours
# later. Run this before a change (baseline), immediately after it, daily from cron, and
# feed the last result to the observer audit. A FAIL is a human's problem (the team cannot
# grant itself permissions), so it is reported as an `action` through bin/lib/notify.sh.
#
# CONF FORMAT, one probe per line, three fields separated by " | ":
#   name | timeout_seconds | shell command (exit 0 = PASS)
# Blank lines and lines starting with # are ignored. Commands run under `bash -o pipefail`
# with the team environment (bin/team-env.sh) sourced, so NTFY_URL, TEAM_DIR, TEAM_PORT and
# the rest are available. Keep every command side-effect free or dry-run.
#
# OUTPUT. One line per probe on stdout (PASS/FAIL name seconds), a summary, exit 1 on any
# FAIL. Durable: $TEAM_DIR/reports/capability-probe.log (append) and
# $TEAM_DIR/health/capability-probe.json (last result, read by the observer).
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# team-env.sh derives the run dir itself and refuses a pre-set TEAM_DIR that differs, so
# source it with TEAM_DIR unset (TEAM_RUN_ID may be set) and restore the caller's choice.
_td_pre="${TEAM_DIR:-}"; unset TEAM_DIR
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh" >/dev/null 2>&1 || true
[ -n "$_td_pre" ] && TEAM_DIR="$_td_pre"
# shellcheck disable=SC1091
. "$repo/bin/lib/notify.sh" 2>/dev/null || true

conf="${1:-${CAPABILITY_PROBE_CONF:-}}"; shift || true
[ -n "$conf" ] && [ -f "$conf" ] || { echo "usage: capability-probe.sh <probes.conf> [--list|--only <name>|--no-notify]" >&2; exit 2; }
mode=run; only=""; notify=1
while [ $# -gt 0 ]; do case "$1" in --list) mode=list ;; --only) only="$2"; shift ;; --no-notify) notify=0 ;; esac; shift; done

td="${TEAM_DIR:-$repo/.team}"; mkdir -p "$td/reports" "$td/health" 2>/dev/null || true
log="$td/reports/capability-probe.log"; json="$td/health/capability-probe.json"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
pass=0; fail=0; failed=""; results=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  name="${line%% | *}"; rest="${line#* | }"; tmo="${rest%% | *}"; cmd="${rest#* | }"
  [ -n "$only" ] && [ "$only" != "$name" ] && continue
  if [ "$mode" = list ]; then printf '%-28s %4ss  %s\n' "$name" "$tmo" "$cmd"; continue; fi
  t0=$(date +%s)
  if timeout "$tmo" bash -o pipefail -c "$cmd" >/dev/null 2>"$td/health/.probe-err"; then st=PASS; pass=$((pass+1)); else st=FAIL; fail=$((fail+1)); failed="$failed $name"; fi
  dt=$(( $(date +%s) - t0 ))
  err="$(head -c 160 "$td/health/.probe-err" 2>/dev/null | tr '\n' ' ')"
  printf '%s %-28s %3ss%s\n' "$st" "$name" "$dt" "$([ "$st" = FAIL ] && printf '  %s' "$err")"
  printf '%s %s %s %ss %s\n' "$(ts)" "$st" "$name" "$dt" "$([ "$st" = FAIL ] && printf '%s' "$err")" >> "$log"
  results="$results{\"name\":\"$name\",\"status\":\"$st\",\"seconds\":$dt},"
done < "$conf"
[ "$mode" = list ] && exit 0
rm -f "$td/health/.probe-err"
printf '{"ts":"%s","pass":%s,"fail":%s,"failed":"%s","probes":[%s]}\n' "$(ts)" "$pass" "$fail" "${failed# }" "${results%,}" > "$json"
echo "capability-probe: pass=$pass fail=$fail${failed:+ failed:$failed}"
printf '%s SUMMARY pass=%s fail=%s%s\n' "$(ts)" "$pass" "$fail" "${failed:+ failed:$failed}" >> "$log"
if [ "$fail" -gt 0 ] && [ "$notify" = 1 ] && declare -F notify_operator >/dev/null 2>&1; then
  notify_operator action "capability probe failed:${failed}" "$fail of $((pass+fail)) capability probes failed on $(hostname) at $(ts). The team may be unable to do part of its work; a permission or a dependency changed. Details: $log"
fi
[ "$fail" -eq 0 ]

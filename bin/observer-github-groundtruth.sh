#!/usr/bin/env bash
# observer-github-groundtruth.sh: fetch current GitHub state for a configured set
# of repos and write it to a file the observer (bin/observer.sh) folds into its
# per-cycle context. Purpose: give the observer HARD GROUND TRUTH about external
# PR/issue state instead of letting it reason from the /is bus log alone — the bus
# observer cannot run Bash, so it had been repeating DAY-OLD "blocked PR" claims
# that were already stale by the time it emitted them.
#
# GENERIC: this script contains NO repo names. The repo list and the fetch knobs
# come entirely from CONFIG (env + a config file). A fork wires its own repo
# list; with no config file present this is a harmless no-op, so the engine
# ships it disabled-by-default.
#
# Config (all optional; env overrides):
#   OBSERVER_GH_CONFIG        path to a config file listing one "owner/repo" per
#                             line ('#' comments and blank lines ignored).
#                             Default: $TEAM_REPO/observer-github.conf
#                             A fork can point this at its own repo list via
#                             team-env.sh.
#   OBSERVER_GH_GROUNDTRUTH   output file. Default:
#                             $TEAM_DIR/observer/github-ground-truth.txt
#   OBSERVER_GH_MIN_INTERVAL  seconds; skip the fetch if the output file's
#                             fetched_at is younger than this (don't hammer gh).
#                             Default 300. Pass --force to bypass.
#   OBSERVER_GH_MERGED_LIMIT  how many recent merged PRs to scan per repo (then
#                             filtered to the merge window). Default 20.
#   OBSERVER_GH_MERGED_HOURS  merge window in hours for "recent merges". Default 24.
#   OBSERVER_GH_TIMEOUT       per-`gh` call timeout, seconds. Default 60.
#
# Failure visibility (per the acceptance contract): on ANY fetch failure the last
# good output file is KEPT UNTOUCHED — its old `fetched_at:` stays put, so a stale
# timestamp is the visible failure signal the observer (and an operator) can see.
# The error detail + its wall-clock time also land in a `<output>.error` sidecar.
# A partial fetch (some repos ok, one failing) is treated as a whole-run failure
# so the file never mixes fresh and stale rows behind one fresh timestamp.
#
# CLI:
#   (no args)   run once, honoring the min-interval gate
#   --force     run once, ignoring the min-interval gate (for tests / manual pulls)
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo_root/bin/team-env.sh"

force=0
[ "${1:-}" = "--force" ] && force=1

config="${OBSERVER_GH_CONFIG:-$TEAM_REPO/observer-github.conf}"
out="${OBSERVER_GH_GROUNDTRUTH:-$TEAM_DIR/observer/github-ground-truth.txt}"
min_interval="${OBSERVER_GH_MIN_INTERVAL:-300}"
merged_limit="${OBSERVER_GH_MERGED_LIMIT:-20}"
merged_hours="${OBSERVER_GH_MERGED_HOURS:-24}"
gh_timeout="${OBSERVER_GH_TIMEOUT:-60}"
err_sidecar="${out}.error"

iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "$(iso) observer-gh: $*" >&2; }

mkdir -p "$(dirname "$out")"

# No config file, or no repos in it -> generic no-op (engine default). Not an error.
if [ ! -f "$config" ]; then
  log "no config at $config; nothing to fetch (generic no-op)"
  exit 0
fi
mapfile -t repos < <(grep -vE '^[[:space:]]*(#|$)' "$config" 2>/dev/null | awk '{print $1}')
if [ "${#repos[@]}" -eq 0 ]; then
  log "config $config lists no repos; nothing to fetch"
  exit 0
fi

command -v gh >/dev/null 2>&1 || { log "gh not on PATH; keeping last file, writing error sidecar"; { echo "$(iso) gh not on PATH"; } > "$err_sidecar"; exit 1; }

# Min-interval gate: parse the previous fetched_at and skip if still fresh. Keyed on
# the file's own recorded timestamp (not mtime) so a KEPT-on-failure stale file
# correctly reads as old and lets the next cycle retry.
if [ "$force" -ne 1 ] && [ -f "$out" ]; then
  prev_iso="$(grep -m1 '^fetched_at:' "$out" 2>/dev/null | sed 's/^fetched_at:[[:space:]]*//')"
  if [ -n "$prev_iso" ]; then
    prev_epoch="$(date -u -d "$prev_iso" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    if [ "$prev_epoch" -gt 0 ] && [ $(( now_epoch - prev_epoch )) -lt "$min_interval" ]; then
      log "last fetch ${prev_iso} is younger than ${min_interval}s; skipping (use --force to override)"
      exit 0
    fi
  fi
fi

# Merge-window cutoff (ISO) for "recent merges".
cutoff_iso="$(date -u -d "-${merged_hours} hours" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')"

tmp="$(mktemp "${TMPDIR:-/tmp}/gh-groundtruth.XXXXXX")" || { log "mktemp failed"; exit 1; }
trap 'rm -f "$tmp"' EXIT
fail=0
fail_detail=""

{
  echo "# github-ground-truth  (bin/observer-github-groundtruth.sh)"
  echo "# HARD ground truth from GitHub. Trust these PR/merge rows over anything in the bus log."
  echo "fetched_at: $(iso)"
  echo "merge_window_hours: ${merged_hours}"
  echo "status: ok"
  echo
} > "$tmp"

for r in "${repos[@]}"; do
  echo "## ${r}" >> "$tmp"

  # OPEN PRs with review decision + merge state.
  open_rows="$(timeout "$gh_timeout" gh pr list --repo "$r" --state open --limit 100 \
      --json number,title,reviewDecision,mergeStateStatus,headRefName,updatedAt,isDraft \
      --jq '.[] | "  #\(.number)  \(.reviewDecision // "NONE")  \(.mergeStateStatus // "?")  draft=\(.isDraft)  \(.headRefName)  upd \(.updatedAt)  \(.title[0:70])"' 2>>"$err_sidecar.tmp")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail=1; fail_detail="${fail_detail} open:${r}(rc=${rc})"
    echo "  OPEN PRs: FETCH FAILED (gh rc=${rc})" >> "$tmp"
  else
    n_open="$(printf '%s' "$open_rows" | grep -c '^  #' 2>/dev/null || echo 0)"
    echo "OPEN PRs (${n_open}):" >> "$tmp"
    [ -n "$open_rows" ] && printf '%s\n' "$open_rows" >> "$tmp" || echo "  (none open)" >> "$tmp"
  fi

  # RECENT MERGES within the window. gh's --jq takes ONE expression and does NOT
  # accept jq's --arg, so the cutoff is interpolated into the expression string
  # (cutoff_iso is our own ISO timestamp, no injection risk).
  merged_jq=".[] | select((\"${cutoff_iso}\" == \"\") or (.mergedAt >= \"${cutoff_iso}\")) | \"  #\(.number)  merged \(.mergedAt)  \(.headRefName)  \(.title[0:60])\""
  merged_rows="$(timeout "$gh_timeout" gh pr list --repo "$r" --state merged --limit "$merged_limit" \
      --json number,title,mergedAt,headRefName \
      --jq "$merged_jq" 2>>"$err_sidecar.tmp")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail=1; fail_detail="${fail_detail} merged:${r}(rc=${rc})"
    echo "  RECENT MERGES: FETCH FAILED (gh rc=${rc})" >> "$tmp"
  else
    n_merged="$(printf '%s' "$merged_rows" | grep -c '^  #' 2>/dev/null || echo 0)"
    echo "RECENT MERGES (last ${merged_hours}h) (${n_merged}):" >> "$tmp"
    [ -n "$merged_rows" ] && printf '%s\n' "$merged_rows" >> "$tmp" || echo "  (none in window)" >> "$tmp"
  fi
  echo >> "$tmp"
done

if [ "$fail" -eq 0 ]; then
  # Full success: publish atomically and clear any stale error sidecar.
  mv -f "$tmp" "$out"
  trap - EXIT
  rm -f "$err_sidecar" "$err_sidecar.tmp"
  log "wrote $out (${#repos[@]} repos)"
  exit 0
else
  # Any failure: KEEP the last good file (its old fetched_at is the stale signal),
  # discard the partial temp, record the error + wall-clock time in the sidecar.
  {
    echo "$(iso) fetch FAILED:${fail_detail}"
    echo "kept last good file: $out"
    [ -f "$err_sidecar.tmp" ] && { echo "--- gh stderr ---"; cat "$err_sidecar.tmp"; }
  } > "$err_sidecar"
  rm -f "$err_sidecar.tmp"
  log "fetch failed (${fail_detail}); kept last good $out (stale fetched_at is the signal); detail in $err_sidecar"
  exit 1
fi

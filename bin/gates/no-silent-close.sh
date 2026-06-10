#!/usr/bin/env bash
# no-silent-close.sh: catch the "silent close" failure mode — a fix PR CLOSED
# WITHOUT merging, with the bug presumed shipped but never actually landed.
# Seen live: a fix PR was closed unmerged, the bug was presumed fixed, and the
# team only discovered days later that nothing shipped, then had to re-diagnose.
# Pure rework at the worst place — a "done" that was not.
#
# What it does (read-only; gh read + local file reads, no writes anywhere):
#   1. Collect PR references from the source(s) — the live ledger by default
#      (the PRs the team currently cares about), optionally the bus log.
#   2. Ask GitHub each PR's state.
#   3. Flag any CLOSED-but-not-MERGED PR as a SILENT-CLOSE RISK to REOPEN. The
#      gate only SURFACES it (surface risk, never silently close); the
#      orchestrator owns reopening the unit — this gate is the trigger, not the
#      actor.
#
# A closed-unmerged fix PR can no longer pass as shipped unnoticed. (The
# deploy-verification half — merged != running in production — is a separate,
# heavier check; this gate stops the cheap, common escape.)
#
# Exit: 0 = no silent-close risk; 1 = at least one risk found; 2 = usage / tooling.
#
# Usage:
#   bin/gates/no-silent-close.sh                      # scan $TEAM_DIR/state.md
#   bin/gates/no-silent-close.sh --source <file> ...  # scan specific file(s)
#   bin/gates/no-silent-close.sh --bus                # also scan the /is bus log
#   bin/gates/no-silent-close.sh owner/repo#123       # check explicit PR ref(s)
#   bin/gates/no-silent-close.sh https://github.com/owner/repo/pull/123
#
# PR references: full GitHub PR URLs found in the sources are authoritative
# (owner and repo come from the URL). Bare refs (`repo#N`, `#N`) resolve against
# GH_DEFAULT_OWNER / GH_DEFAULT_REPO.
#
# Allowlist: a closed-unmerged PR that was closed ON PURPOSE (superseded by
# another PR, or dropped by a product decision) is NOT a silent close. List such
# PRs, one per line as `owner/repo#N  reason`, in
# $TEAM_DIR/no-silent-close-allowlist.txt (or $NO_SILENT_CLOSE_ALLOWLIST). They
# are reported as "closed-intended" and do NOT fail the gate — so repeated runs
# do not re-alarm on known, adjudicated closes.
#
# Env: GH_DEFAULT_OWNER, GH_DEFAULT_REPO (resolve bare `repo#N` / `#N` refs);
#      NO_SILENT_CLOSE_MAX (cap PRs queried, default 80);
#      NO_SILENT_CLOSE_ALLOWLIST (path; default $TEAM_DIR/no-silent-close-allowlist.txt).

set -uo pipefail

DEFAULT_OWNER="${GH_DEFAULT_OWNER:-}"
DEFAULT_REPO="${GH_DEFAULT_REPO:-}"
MAX="${NO_SILENT_CLOSE_MAX:-80}"
BUS_LOG="${BUS_LOG:-$HOME/.claude/data/inter-session/messages.log}"
ALLOWLIST="${NO_SILENT_CLOSE_ALLOWLIST:-${TEAM_DIR:-.}/no-silent-close-allowlist.txt}"
sources=()
scan_bus=0
explicit=()

while [ $# -gt 0 ]; do
  case "$1" in
    --source) sources+=("$2"); shift 2 ;;
    --bus) scan_bus=1; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) explicit+=("$1"); shift ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "no-silent-close: gh CLI not found" >&2; exit 2; }

# Default source: the live ledger.
if [ "${#sources[@]}" -eq 0 ] && [ "${#explicit[@]}" -eq 0 ]; then
  sources+=("${TEAM_DIR:-.}/state.md")
fi
[ "$scan_bus" -eq 1 ] && sources+=("$BUS_LOG")

# Collect "owner/repo<TAB>number" pairs from full PR URLs in the sources plus
# explicit refs. Full URLs are authoritative for owner and repo; bare refs need
# GH_DEFAULT_OWNER / GH_DEFAULT_REPO.
collect() {
  local f
  for f in "${sources[@]}"; do
    [ -f "$f" ] || continue
    grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$f" 2>/dev/null \
      | sed -E 's#github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)#\1\t\2#'
  done
  local r
  for r in "${explicit[@]+"${explicit[@]}"}"; do
    case "$r" in
      *github.com/*/pull/*)
        printf '%s\n' "$r" | sed -E 's#.*github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+).*#\1\t\2#' ;;
      */*\#*) printf '%s\t%s\n' "${r%%#*}" "${r#*#}" ;;
      \#*)
        if [ -n "$DEFAULT_OWNER" ] && [ -n "$DEFAULT_REPO" ]; then
          printf '%s/%s\t%s\n' "$DEFAULT_OWNER" "$DEFAULT_REPO" "${r#\#}"
        else
          echo "no-silent-close: bare ref '$r' needs GH_DEFAULT_OWNER + GH_DEFAULT_REPO" >&2
        fi ;;
      *\#*)
        if [ -n "$DEFAULT_OWNER" ]; then
          printf '%s/%s\t%s\n' "$DEFAULT_OWNER" "${r%%#*}" "${r#*#}"
        else
          echo "no-silent-close: ref '$r' needs GH_DEFAULT_OWNER (or use owner/repo#N)" >&2
        fi ;;
      *) echo "no-silent-close: unrecognized PR ref '$r' (use a full URL or owner/repo#N)" >&2 ;;
    esac
  done
}

pairs="$(collect | awk 'NF==2' | sort -u)"
if [ -z "$pairs" ]; then
  echo "no-silent-close: no PR references found in the source(s); nothing to check."
  exit 0
fi

total="$(printf '%s\n' "$pairs" | grep -c .)"
if [ "$total" -gt "$MAX" ]; then
  echo "no-silent-close: $total PR refs exceed cap $MAX; checking the $MAX most recent (raise NO_SILENT_CLOSE_MAX to scan all)."
  pairs="$(printf '%s\n' "$pairs" | sort -t$'\t' -k2 -n | tail -n "$MAX")"
fi

# Is "owner/repo#N" on the allowlist? (exact match of the first token on a
# non-comment line)
allowed() {
  [ -f "$ALLOWLIST" ] || return 1
  grep -qE "^[[:space:]]*${1//\//\\/}([[:space:]]|$)" "$ALLOWLIST" 2>/dev/null
}

risk=0; checked=0; merged=0; open=0; errors=0; intended=0
risks_report=""
while IFS=$'\t' read -r repo num; do
  if [ -z "$repo" ] || [ -z "$num" ]; then continue; fi
  checked=$((checked+1))
  # state is OPEN | CLOSED | MERGED (MERGED is its own state in gh)
  out="$(gh pr view "$num" --repo "$repo" --json state,title,closedAt,url --jq '[.state,.title,.closedAt,.url]|@tsv' 2>/dev/null)" || { errors=$((errors+1)); echo "  ?    ${repo}#${num}  (gh view failed — repo/number/scope?)"; continue; }
  state="$(printf '%s' "$out" | cut -f1)"
  title="$(printf '%s' "$out" | cut -f2)"
  closed="$(printf '%s' "$out" | cut -f3)"
  url="$(printf '%s' "$out" | cut -f4)"
  case "$state" in
    MERGED) merged=$((merged+1)) ;;
    OPEN)   open=$((open+1)) ;;
    CLOSED)
      if allowed "${repo}#${num}"; then
        intended=$((intended+1))
        echo "  closed-intended (allowlisted)  ${repo}#${num}  ${title}"
      else
        risk=$((risk+1))
        risks_report+="  SILENT-CLOSE RISK  ${repo}#${num}  closed=${closed}  ${title}"$'\n'"      ${url}"$'\n'
      fi
      ;;
  esac
done <<< "$pairs"

echo "no-silent-close: checked ${checked} PR(s) — merged=${merged} open=${open} closed-intended=${intended} closed-unmerged-RISK=${risk} gh-errors=${errors}"
if [ "$risk" -gt 0 ]; then
  echo
  echo "SILENT-CLOSE RISK — these PRs were CLOSED WITHOUT MERGING. The linked fix may"
  echo "NOT be shipped. Reopen the unit and re-confirm on the live path before any"
  echo "'done' (surface risk, never silently close; verify deployed, not just merged):"
  printf '%s' "$risks_report"
fi
[ "$risk" -eq 0 ]

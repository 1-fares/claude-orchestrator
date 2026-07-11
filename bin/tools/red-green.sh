#!/usr/bin/env bash
# red-green.sh: run a verify command and save a stamped log as red (expected-fail)
# or green (expected-pass) evidence for a unit. Produces the paired artifact the
# tester gate and the ledger `verify:` field point at. Call once before the fix
# (red) and once after (green); the exit code is the command's own.
#
#   bin/tools/red-green.sh <red|green> <unit> "<verify-cmd>"
#
# Pass the verify command as ONE argument (quote it), exactly as a ledger
# `verify:` line reads. It runs via `bash -c`, so `&&`, pipes, and redirects
# work. Quote the whole thing so inner quotes survive, e.g.
#   red-green.sh red parser 'pytest -k "foo bar" && ruff check .'
# Extra unquoted args are joined with spaces (their own quoting is lost).
#
# Writes under $TEAM_DIR/evidence/<unit>/ (or ./.evidence/<unit>/ outside a run)
# and prints the log path on stdout.
set -uo pipefail

phase="${1:-}"; unit="${2:-}"
case "$phase" in red|green) ;; *) echo 'usage: red-green.sh <red|green> <unit> "<verify-cmd>"' >&2; exit 2 ;; esac
[ -n "$unit" ] || { echo 'usage: red-green.sh <red|green> <unit> "<verify-cmd>"' >&2; exit 2; }
shift 2
cmd="$*"
[ -n "$cmd" ] || { echo "red-green: no verify command given" >&2; exit 2; }

base="${TEAM_DIR:-./.evidence}"; [ -n "${TEAM_DIR:-}" ] && base="$TEAM_DIR/evidence"
evid="$base/$unit"; mkdir -p "$evid"
log="$evid/$phase.log"

{
  echo "# unit:    $unit"
  echo "# phase:   $phase"
  echo "# cmd:     $cmd"
  echo "# started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# ----------------------------------------------------------------------"
} >"$log"

bash -c "$cmd" >>"$log" 2>&1
rc=$?

{
  echo "# ----------------------------------------------------------------------"
  echo "# exit:    $rc"
} >>"$log"

if [ "$phase" = red ] && [ "$rc" -eq 0 ]; then
  echo "WARN: red capture exited 0 (expected a failing test). Is it actually red yet?" >&2
elif [ "$phase" = green ] && [ "$rc" -ne 0 ]; then
  echo "WARN: green capture exited $rc (expected pass). Not green yet." >&2
fi

echo "$log"
exit "$rc"

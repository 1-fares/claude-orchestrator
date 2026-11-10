#!/usr/bin/env bash
# run-all.sh: run the test suite, one file at a time.
#
# Usage: bin/tests/run-all.sh [--list] [<test> ...]
#   No argument: every bin/tests/*test.sh (both the -test.sh and the .test.sh
#   naming), then every tests/b9/*.sh. Arguments select a subset; each is a path
#   (relative to the clone or absolute) or a bare file name looked up in
#   bin/tests/ and tests/b9/.
#   --list  print the files that would run, one per line, and run nothing
#           (exit 1 if a selected file is not found).
#
# Prints one line per file (rc, seconds, file), then the skips (rc 0 with a
# "SKIP:" line: a missing dependency, nothing verified) and the failures with the
# path of their log and their first FAIL line. The last line gives the passed,
# failed and skipped counts. Exit 0 if no file failed, 1 otherwise.
#
# Env:
#   RUN_ALL_TIMEOUT=600   seconds per file before it is stopped (rc 124)
#   RUN_ALL_LOG_DIR=DIR   per-file output; default ${TMPDIR:-/tmp}/orch-run-all-<uid>-<clone hash>,
#                         overwritten by the next run of the same clone
#
# Sources nothing from the team environment, and runs every file with the team
# identity variables removed, so no test can inherit a live run's TEAM_RUN_ID,
# TEAM_DIR or tmux socket (docs/incident-2026-07-11-test-cleanup-wiped-live-run.md).
# Sequential by design: the tests start tmux servers, daemons and fixed ports.

set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo" || exit 2
tmo="${RUN_ALL_TIMEOUT:-600}"
list=0; [ "${1:-}" = --list ] && { list=1; shift; }

files=()
if [ "$#" -eq 0 ]; then
  for f in bin/tests/*test.sh tests/b9/*.sh; do [ -f "$f" ] && files+=("$f"); done
else
  for a in "$@"; do
    if [ -f "$a" ]; then files+=("$a")
    elif [ -f "bin/tests/$a" ]; then files+=("bin/tests/$a")
    elif [ -f "tests/b9/$a" ]; then files+=("tests/b9/$a")
    else files+=("$a")   # reported as not found below
    fi
  done
fi

if [ "$list" = 1 ]; then
  lrc=0
  for f in "${files[@]}"; do
    if [ -f "$f" ]; then echo "$f"; else echo "$f  (not found)"; lrc=1; fi
  done
  exit "$lrc"
fi

logdir="${RUN_ALL_LOG_DIR:-${TMPDIR:-/tmp}/orch-run-all-$(id -u)-$(printf '%s' "$repo" | cksum | cut -d' ' -f1)}"
mkdir -p "$logdir" || exit 2

child=""
trap '[ -n "$child" ] && kill -TERM "$child" 2>/dev/null; echo "run-all: interrupted" >&2; exit 130' INT TERM

failed=(); skipped=(); n=0
for f in "${files[@]}"; do
  n=$((n+1))
  log="$logdir/$(printf '%s' "$f" | tr '/' '_').log"
  if [ ! -f "$f" ]; then
    printf '%-56s rc=%-3s %5ss  (not found)\n' "$f" 127 0
    failed+=("$f rc=127 (not found)"); continue
  fi
  start=$SECONDS
  # timeout leads its own process group and signals the whole group on expiry.
  env -u TEAM_RUN_ID -u TEAM_DIR -u TEAM_SESSION -u TEAM_PORT -u INTER_SESSION_PORT \
      -u TEAM_TMUX -u TEAM_DIR_ALLOW_OVERRIDE \
      timeout -k 10 "$tmo" bash "$f" > "$log" 2>&1 < /dev/null &
  child=$!
  wait "$child"; rc=$?
  child=""
  secs=$((SECONDS - start))
  note=""; [ "$rc" = 124 ] && note="  (timeout after ${tmo}s)"
  # A few tests exit 0 with a "SKIP: <why>" line when a dependency is missing: not a pass.
  skip=""; [ "$rc" = 0 ] && skip="$(grep -m1 '^SKIP:' "$log")" && { note="  ($skip)"; skipped+=("$f $skip"); }
  printf '%-56s rc=%-3s %5ss%s\n' "$f" "$rc" "$secs" "$note"
  if [ "$rc" != 0 ]; then
    # The first FAIL line of the log (colour codes removed), so the summary names the assertion.
    first="$(grep -m1 -E 'FAIL|not ok' "$log" | sed 's/\x1b\[[0-9;]*m//g; s/^[[:space:]]*//' | cut -c1-200)"
    failed+=("$f rc=$rc log: $log${first:+$'\n'      first failure: $first}")
  fi
done

echo
if [ "${#skipped[@]}" -gt 0 ]; then
  echo "run-all: ${#skipped[@]} file(s) skipped, verified nothing:"
  for x in "${skipped[@]}"; do echo "  $x"; done
fi
if [ "${#failed[@]}" -gt 0 ]; then
  echo "run-all: ${#failed[@]} file(s) failed:"
  for x in "${failed[@]}"; do echo "  $x"; done
fi
echo "run-all: $((n - ${#failed[@]} - ${#skipped[@]})) passed, ${#failed[@]} failed, ${#skipped[@]} skipped, of $n file(s) (logs: $logdir)"
[ "${#failed[@]}" -eq 0 ]

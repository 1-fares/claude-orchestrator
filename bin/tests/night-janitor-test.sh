#!/usr/bin/env bash
# night-janitor-test.sh: fixture tests for bin/night-janitor.sh — bak
# thinning, attachments expiry, dream-archive expiry, bus spill/messages
# retention, and dry-run-by-default (nothing changes without --apply).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/isolate.sh"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"
isolate_assert

bus="$(mktemp -d)"
trap 'rm -rf "$TEAM_DIR" "$bus"' EXIT
mkdir -p "$TEAM_DIR/attachments" "$TEAM_DIR/dreams/archive" "$bus/spill"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

janitor() {
  NJ_BUS_DIR="$bus" NJ_KEEP_BAKS=2 NJ_ATTACH_DAYS=7 NJ_ARCHIVE_DAYS=30 \
  NJ_BUS_KEEP_DAYS=7 NJ_BUS_LOG_MAX=1000 NJ_BUS_KEEP_LINES=5 \
  "$repo/bin/night-janitor.sh" "$@" 2>&1
}

# Fixtures: 4 baks (2 old), old + new attachments, old archive dir, bus.
for i in 1 2 3 4; do
  echo "bak $i" > "$TEAM_DIR/state.md.bak-2026060${i}-000000"
done
touch -d '10 days ago' "$TEAM_DIR/state.md.bak-20260601-000000" "$TEAM_DIR/state.md.bak-20260602-000000"
echo new > "$TEAM_DIR/attachments/new.png"
echo old > "$TEAM_DIR/attachments/old.mp4"
touch -d '20 days ago' "$TEAM_DIR/attachments/old.mp4"
mkdir -p "$TEAM_DIR/dreams/archive/20260501-0200"
echo x > "$TEAM_DIR/dreams/archive/20260501-0200/f"
touch -d '60 days ago' "$TEAM_DIR/dreams/archive/20260501-0200"
echo keepme > "$bus/spill/new-spill"
echo oldspill > "$bus/spill/old-spill"
touch -d '30 days ago' "$bus/spill/old-spill"
for i in $(seq 1 200); do echo "{\"msg\":$i}" >> "$bus/messages.log"; done

# --- dry run: nothing changes -------------------------------------------
out="$(janitor)"
check "dry-run: mentions bak thinning" "$(grep -q 'bak: gzip+move' <<<"$out"; echo $?)"
check "dry-run: baks still present" "$([ "$(ls "$TEAM_DIR"/state.md.bak-* | wc -l)" -eq 4 ]; echo $?)"
check "dry-run: old attachment kept" "$([ -f "$TEAM_DIR/attachments/old.mp4" ]; echo $?)"
check "dry-run: bus log untouched" "$([ "$(wc -l < "$bus/messages.log")" -eq 200 ]; echo $?)"

# --- apply ---------------------------------------------------------------
out="$(janitor --apply)"
check "apply: 2 newest baks kept" "$([ "$(ls "$TEAM_DIR"/state.md.bak-* | wc -l)" -eq 2 ]; echo $?)"
check "apply: old baks archived gz" "$([ "$(ls "$TEAM_DIR"/dreams/archive/janitor/*.gz | wc -l)" -eq 2 ]; echo $?)"
check "apply: old attachment deleted" "$([ ! -f "$TEAM_DIR/attachments/old.mp4" ]; echo $?)"
check "apply: new attachment kept" "$([ -f "$TEAM_DIR/attachments/new.png" ]; echo $?)"
check "apply: old dream-archive dir expired" "$([ ! -d "$TEAM_DIR/dreams/archive/20260501-0200" ]; echo $?)"
check "apply: old spill bundled" "$([ -n "$(ls "$bus"/spill-archive/*.tar.gz 2>/dev/null)" ]; echo $?)"
check "apply: old spill removed" "$([ ! -f "$bus/spill/old-spill" ]; echo $?)"
check "apply: fresh spill kept" "$([ -f "$bus/spill/new-spill" ]; echo $?)"
check "apply: messages.log truncated to keep-lines" "$([ "$(wc -l < "$bus/messages.log")" -eq 5 ]; echo $?)"
check "apply: messages.log archive holds full copy" "$(zcat "$bus"/spill-archive/messages-*.log.gz | grep -q '"msg":1}'; echo $?)"
check "apply: janitor.log written" "$([ -s "$TEAM_DIR/janitor.log" ]; echo $?)"

# spill archive content check
check "apply: spill archive holds old content" "$(tar -xzOf "$bus"/spill-archive/[0-9]*.tar.gz 2>/dev/null | grep -q oldspill; echo $?)"

echo
echo "night-janitor: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

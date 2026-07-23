#!/usr/bin/env bash
# night-janitor.sh: deterministic retention/expiry for a run's NON-knowledge
# payload. The dreamer (bin/dreamer.sh) rewrites the knowledge ledgers; this
# script only rotates and expires bulk artifacts that carry no unique
# information: ledger backup copies, re-downloadable ticket media, aged dream
# archives, and (opt-in) an inter-session bus directory. No LLM, no judgement
# calls; every rule is a plain age/count threshold.
#
# DRY-RUN BY DEFAULT (prints the plan); --apply executes. Wire cron with
# --apply. Same convention as bin/cleanup.sh.
#
# What it does (all under the run dir unless noted):
#   1. state.md.bak-* thinning: keep the newest NJ_KEEP_BAKS, gzip the rest
#      into dreams/archive/janitor/ and remove the originals.
#   2. attachments/ expiry: files older than NJ_ATTACH_DAYS are DELETED —
#      they were downloaded FROM the ticket tracker (bin/gh-attachments.sh)
#      and remain re-downloadable there. 0 disables.
#   3. dreams/archive/ expiry: archive dirs older than NJ_ARCHIVE_DAYS are
#      deleted. This is the one place raw dreamed evidence ever expires;
#      default 90 days. 0 disables.
#   4. Bus retention (ONLY when NJ_BUS_DIR is set; the bus lives outside the
#      run dir and is ecosystem-specific): spill/ files older than
#      NJ_BUS_KEEP_DAYS are bundled into spill-archive/<stamp>.tar.gz and
#      removed; messages.log over NJ_BUS_LOG_MAX bytes is archived-compressed
#      whole and truncated in place to its last NJ_BUS_KEEP_LINES lines
#      (O_APPEND writers keep appending; skipped if the log grew mid-pass).
#
# Env: NJ_KEEP_BAKS=3 NJ_ATTACH_DAYS=30 NJ_ARCHIVE_DAYS=90
#      NJ_BUS_DIR= NJ_BUS_KEEP_DAYS=21 NJ_BUS_LOG_MAX=16777216 NJ_BUS_KEEP_LINES=4000
# Run id: $TEAM_RUN_ID, else newest .team-r* dir, else legacy .team/.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  ""|--dry-run) ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "night-janitor: unknown flag $1" >&2; exit 2 ;;
esac

if [ -z "${TEAM_RUN_ID:-}" ]; then
  latest="$(ls -1dt "$repo"/.team-r*/ 2>/dev/null | head -1)"
  if [ -n "$latest" ]; then
    TEAM_RUN_ID="$(basename "$latest" | sed 's/^\.team-//')"
    export TEAM_RUN_ID
  fi
fi
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"
[ -d "$TEAM_DIR" ] || { echo "night-janitor: no run dir at $TEAM_DIR"; exit 0; }

keep_baks="${NJ_KEEP_BAKS:-3}"
attach_days="${NJ_ATTACH_DAYS:-30}"
archive_days="${NJ_ARCHIVE_DAYS:-90}"
bus_dir="${NJ_BUS_DIR:-}"
bus_keep_days="${NJ_BUS_KEEP_DAYS:-21}"
bus_log_max="${NJ_BUS_LOG_MAX:-16777216}"
bus_keep_lines="${NJ_BUS_KEEP_LINES:-4000}"
stamp="$(date -u '+%Y%m%d-%H%M')"
jlog="$TEAM_DIR/janitor.log"

note() {
  printf '%s\n' "$*"
  [ "$apply" -eq 1 ] && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$jlog"
}
mode="DRY-RUN"; [ "$apply" -eq 1 ] && mode="APPLY"
note "night-janitor [$mode] run=$TEAM_DIR"

# 1. bak thinning ---------------------------------------------------------
jarch="$TEAM_DIR/dreams/archive/janitor"
mapfile -t baks < <(ls -1t "$TEAM_DIR"/state.md.bak-* 2>/dev/null)
if [ "${#baks[@]}" -gt "$keep_baks" ]; then
  for f in "${baks[@]:$keep_baks}"; do
    note "bak: gzip+move $(basename "$f") ($(stat -c%s "$f") bytes)"
    if [ "$apply" -eq 1 ]; then
      mkdir -p "$jarch"
      gzip -c "$f" > "$jarch/$(basename "$f").gz" && rm -f "$f"
    fi
  done
else
  note "bak: ${#baks[@]} present, <= keep($keep_baks), nothing to do"
fi

# 2. attachments expiry ---------------------------------------------------
if [ "$attach_days" -gt 0 ] && [ -d "$TEAM_DIR/attachments" ]; then
  n=0; bytes=0
  while IFS= read -r f; do
    n=$((n+1)); bytes=$((bytes + $(stat -c%s "$f" 2>/dev/null || echo 0)))
    note "attachments: expire $(basename "$f")"
    [ "$apply" -eq 1 ] && rm -f "$f"
  done < <(find "$TEAM_DIR/attachments" -type f -mtime "+$attach_days" 2>/dev/null)
  note "attachments: $n file(s), $bytes bytes past ${attach_days}d"
else
  note "attachments: disabled or no dir"
fi

# 3. dream-archive expiry -------------------------------------------------
if [ "$archive_days" -gt 0 ] && [ -d "$TEAM_DIR/dreams/archive" ]; then
  while IFS= read -r d; do
    note "dream-archive: expire $(basename "$d")"
    [ "$apply" -eq 1 ] && rm -rf "$d"
  done < <(find "$TEAM_DIR/dreams/archive" -mindepth 1 -maxdepth 1 -mtime "+$archive_days" 2>/dev/null)
fi

# 4. bus retention (opt-in) ----------------------------------------------
if [ -n "$bus_dir" ] && [ -d "$bus_dir" ]; then
  sa="$bus_dir/spill-archive"
  # spill files
  if [ -d "$bus_dir/spill" ]; then
    mapfile -t old_spill < <(find "$bus_dir/spill" -type f -mtime "+$bus_keep_days" 2>/dev/null)
    if [ "${#old_spill[@]}" -gt 0 ]; then
      note "bus: ${#old_spill[@]} spill file(s) past ${bus_keep_days}d -> spill-archive/$stamp.tar.gz"
      if [ "$apply" -eq 1 ]; then
        mkdir -p "$sa"
        printf '%s\n' "${old_spill[@]}" | tar -czf "$sa/$stamp.tar.gz" -T - 2>/dev/null \
          && printf '%s\n' "${old_spill[@]}" | xargs -r rm -f
      fi
    else
      note "bus: no spill files past ${bus_keep_days}d"
    fi
  fi
  # messages.log
  ml="$bus_dir/messages.log"
  if [ -f "$ml" ]; then
    sz="$(stat -c%s "$ml")"
    if [ "$sz" -gt "$bus_log_max" ]; then
      note "bus: messages.log $sz bytes > $bus_log_max; archive + keep last $bus_keep_lines lines"
      if [ "$apply" -eq 1 ]; then
        mkdir -p "$sa"
        gzip -c "$ml" > "$sa/messages-$stamp.log.gz"
        tail -n "$bus_keep_lines" "$ml" > "$ml.janitor-tail"
        # Lost-append guard: only truncate if the log did not grow mid-pass.
        if [ "$(stat -c%s "$ml")" -eq "$sz" ]; then
          cat "$ml.janitor-tail" > "$ml"   # truncate-in-place; O_APPEND-safe
          note "bus: messages.log truncated to last $bus_keep_lines lines (full copy in spill-archive)"
        else
          note "bus: messages.log grew mid-pass; SKIPPED truncation (archive copy kept)"
        fi
        rm -f "$ml.janitor-tail"
      fi
    else
      note "bus: messages.log $sz bytes, under cap"
    fi
  fi
else
  note "bus: NJ_BUS_DIR unset/missing, skipped"
fi

note "night-janitor [$mode] done"

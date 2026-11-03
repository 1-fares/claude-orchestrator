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
#   5. Docker build cache (ONLY when NJ_DOCKER_BUILDER_PRUNE=1): per builder, exactly
#      `docker buildx prune --builder <name> --force --filter until=23h`, nothing else --
#      never images, containers, volumes or networks, never --all. Builders: `default`
#      (plain `docker build`, the cache `docker system df` shows) and the cron user's
#      current buildx builder when it differs (a docker-container builder `system df` does
#      not show). The name is ALWAYS passed: `docker builder prune` is pinned to `default`
#      whatever is current. Sizes from `buildx du --builder <name>`. Skipped, with the
#      process named, while any docker build / buildx build|b|bake / compose build / compose
#      up|run|create --build / compose run / compose watch runs. Docker absent or its daemon
#      unreachable: one line, the rest continues.
#
# Env: NJ_KEEP_BAKS=3 NJ_ATTACH_DAYS=30 NJ_ARCHIVE_DAYS=90
#      NJ_BUS_DIR= NJ_BUS_KEEP_DAYS=21 NJ_BUS_LOG_MAX=16777216 NJ_BUS_KEEP_LINES=4000
#      NJ_DOCKER_BUILDER_PRUNE=0 (rule 5; 1 enables)
# Run id: $TEAM_RUN_ID, else newest .team-r* dir, else legacy .team/.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  ""|--dry-run) ;;
  -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
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

# Returns the janitor.log write status under --apply, 0 in a dry run. It was `[ apply ] &&
# printf`, which returns 1 in a dry run; the script ends on a note, so every dry run exited 1.
# An if keeps a failed log write visible under --apply.
note() {
  printf '%s\n' "$*"
  if [ "$apply" -eq 1 ]; then
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$jlog"
  fi
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

# 5. docker build cache (opt-in) -----------------------------------------
# The ONLY prune this script can issue: `docker buildx prune --builder <name>` + these constant
# arguments. <name> comes from `docker buildx inspect` and must be a plain builder name.
# `until` is last-used, not age, and after a buildkitd restart deleting a layer bumps its parent's
# last-used to now: 24h kept that parent ~1s inside the next nightly cutoff, so chains never drained.
NJ_PRUNE_ARGS=(--force --filter until=23h)

# Print "pid argv0 ... token" for every running process that is a docker build. Reads the real
# process table (/proc/<pid>/cmdline, NUL-separated argv) with bash builtins only: no ps,
# no pgrep -f, no grep over a command line, so nothing this janitor runs can match its own
# pattern. A process counts when argv[0]'s basename is a docker CLI (docker, the compose
# and buildx plugins, which run as docker-compose / docker-buildx argv0, or standalone
# docker-compose / buildx) AND some later argument is exactly "build", "b" (buildx alias),
# "bake", "--build" or "--build=..." (compose up/run/create), "run" (compose run builds a
# missing image) or "watch" (compose watch rebuilds). That over-matches (`docker run img
# build` also skips a night), which is the safe direction. Only argv0 and the matched token
# are printed: the rest of a build's argv can hold --build-arg secrets.
nj_docker_builds() {
  local d pid a0 arg hit comp run
  local -a av
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] || [ "$pid" = "$BASHPID" ] && continue
    # The brace group puts the redirect inside the silenced scope: a process that exits
    # mid-scan otherwise prints "No such file" into the cron log.
    { mapfile -d '' -t av < "$d/cmdline"; } 2>/dev/null || continue
    [ "${#av[@]}" -ge 2 ] || continue
    a0="${av[0]##*/}"
    case "$a0" in docker|docker-compose|docker-buildx|buildx|com.docker.cli) ;; *) continue ;; esac
    hit=0; comp=0; run=0
    [ "$a0" = docker-compose ] && comp=1
    for arg in "${av[@]:1}"; do
      case "$arg" in
        build|b|bake|--build|--build=*|watch) hit=1; break ;;
        compose) comp=1 ;;
        run) run=1 ;;
      esac
    done
    # compose run builds a missing image: "run" counts only under compose.
    [ "$hit" -eq 0 ] && [ "$run" -eq 1 ] && [ "$comp" -eq 1 ] && { hit=1; arg=run; }
    [ "$hit" -eq 1 ] && printf '%s %s ... %s\n' "$pid" "$a0" "$arg"
  done
  return 0
}
nj_cache_size() {   # nj_cache_size <builder> -> "<total> (reclaimable <r>)" of that builder, or "unknown"
  local k v tot="" rec=""
  while IFS=$'\t' read -r k v; do
    v="${v#"${v%%[![:space:]]*}"}"
    case "$k" in Total:) tot="$v" ;; Reclaimable:) rec="$v" ;; esac
  done < <(timeout 120 docker buildx du --builder "$1" 2>/dev/null | tail -n 3)
  [ -n "$tot" ] && printf '%s (reclaimable %s)\n' "$tot" "${rec:-?}" || echo unknown
}
nj_current_builder() {   # the cron user's current buildx builder, or nothing
  local k v
  while read -r k v; do [ "$k" = "Name:" ] && { echo "$v"; return 0; }; done \
    < <(timeout 60 docker buildx inspect 2>/dev/null | head -n 1)
  return 0
}
if [ "${NJ_DOCKER_BUILDER_PRUNE:-0}" = 1 ]; then
  if ! command -v docker >/dev/null 2>&1; then
    note "docker-cache: docker not installed, skipped"
  elif ! timeout 30 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    note "docker-cache: docker daemon unreachable, skipped"
  else
    targets=(default)
    cur="$(nj_current_builder)"
    case "$cur" in
      ''|default) ;;
      *[!A-Za-z0-9._-]*|-*) note "docker-cache: current builder name not a plain name, ignored (default only)" ;;
      *) targets+=("$cur") ;;
    esac
    mapfile -t builds < <(nj_docker_builds)
    if [ "${#builds[@]}" -gt 0 ]; then
      for b in "${builds[@]}"; do note "docker-cache: SKIPPED, build running: pid $b"; done
      for t in "${targets[@]}"; do note "docker-cache: builder $t cache $(nj_cache_size "$t"), left alone"; done
    else
      for t in "${targets[@]}"; do
        before="$(nj_cache_size "$t")"
        if [ "$apply" -eq 1 ]; then
          note "docker-cache: builder $t cache before $before; running: docker buildx prune --builder $t ${NJ_PRUNE_ARGS[*]}"
          out="$(timeout 900 docker buildx prune --builder "$t" "${NJ_PRUNE_ARGS[@]}" 2>&1)"; rc=$?
          reclaimed="$(printf '%s\n' "$out" | sed -n -E 's/^Total( reclaimed space)?:[[:space:]]*//p' | tail -n 1)"
          [ "$rc" -eq 124 ] && note "docker-cache: prune of builder $t TIMED OUT after 900s (client killed)"
          note "docker-cache: builder $t prune rc=$rc, reclaimed ${reclaimed:-unknown}, cache after $(nj_cache_size "$t")"
        else
          note "docker-cache: would run: docker buildx prune --builder $t ${NJ_PRUNE_ARGS[*]} (builder $t cache now $before)"
        fi
      done
    fi
  fi
else
  note "docker-cache: NJ_DOCKER_BUILDER_PRUNE unset, skipped"
fi

note "night-janitor [$mode] done"

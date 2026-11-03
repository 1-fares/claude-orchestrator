#!/usr/bin/env bash
# night-janitor-docker-test.sh: rule 5 of bin/night-janitor.sh (docker build cache).
# The real docker is NEVER reachable from here: PATH is a fake `docker` plus a mirror of
# /usr/bin and /bin with every docker* entry left out, so a missing fake fails as "docker
# not installed" instead of pruning the real build cache. The fake logs its full argv, one
# invocation per line, and every case asserts that log line by line.
# Build processes are REAL processes on the box's process table, started with `exec -a` so
# argv[0] is a docker CLI, and each one is checked in /proc before the case relies on it.
# The fake models builder selection like Docker 29: `docker builder ...` acts on `default`
# (a review found the alias is pinned there), `docker buildx ...` on the current builder unless
# --builder names one. Each builder has its own cache size (default 1.2GB, the current
# fake-builder 3.6GB), so a prune that hits the wrong builder leaves a visible non-zero size.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
if [ ! -r "$repo/bin/tests/lib/isolate.sh" ]; then
  echo "FATAL: $repo/bin/tests/lib/isolate.sh is missing; refusing to run" >&2; exit 99
fi
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/isolate.sh"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"
command -v isolate_assert >/dev/null 2>&1 || { echo "FATAL: isolate_assert undefined; refusing to run" >&2; exit 99; }
isolate_assert

scratch="$(mktemp -d)"
pids=()
cleanup() {
  local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$TEAM_DIR" "$scratch"
}
trap cleanup EXIT
mkdir -p "$TEAM_DIR" "$scratch/attach" "$scratch/fake" "$scratch/sane"

# Mirror of the system tool dirs without any docker binary.
for d in /usr/local/bin /usr/bin /bin; do
  for f in "$d"/*; do
    b="${f##*/}"
    case "$b" in docker*|com.docker*|buildx|buildctl) continue ;; esac
    [ -e "$scratch/sane/$b" ] || [ -L "$scratch/sane/$b" ] || ln -s "$f" "$scratch/sane/$b"
  done
done

calls="$scratch/calls.log"; : > "$calls.all"
cat > "$scratch/fake/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG.all"
cur="${FAKE_CURRENT:-fake-builder}"
# Which builder does this call act on?
target=""; prev=""
for a in "$@"; do [ "$prev" = --builder ] && target="$a"; prev="$a"; done
case "$1" in builder) target="${target:-default}" ;; buildx) target="${target:-$cur}" ;; esac
size() { cat "$FAKE_DOCKER_LOG.size.$1" 2>/dev/null || case "$1" in default) echo 1.2GB ;; *) echo 3.6GB ;; esac; }
case "$1 ${2:-}" in
  info*) [ "${FAKE_DOCKER_DAEMON:-up}" = up ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }; echo 29.1.3 ;;
  "buildx inspect") printf 'Name:          %s\nDriver:        docker-container\n' "$target" ;;
  "buildx du"|"builder du") c="$(size "$target")"
               printf 'ID\tRECLAIMABLE\tSIZE\tLAST ACCESSED\nabc\ttrue\t%s\t4 days ago\nReclaimable:\t%s\nTotal:\t\t%s\n' "$c" "$c" "$c" ;;
  # Default: the shape buildx v0.34.1 prints for a real prune: a tab table, then "Total:<TAB><size>".
  # legacy: the `docker builder prune` wording.
  "buildx prune"|"builder prune") c="$(size "$target")"
               if [ "${FAKE_PRUNE_FORMAT:-buildx}" = legacy ]; then
                 echo "ID  RECLAIMABLE  SIZE"; echo "Total reclaimed space: $c"
               else
                 printf 'ID\t\t\t\t\t\tRECLAIMABLE\tSIZE\t\tLAST ACCESSED\nexamplecacherecord0000001               \ttrue \t\t%s   \t28 seconds ago\nTotal:\t%s\n' "$c" "$c"
               fi
               echo 0B > "$FAKE_DOCKER_LOG.size.$target" ;;
esac
exit 0
EOF
chmod +x "$scratch/fake/docker"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

INFO="info --format {{.ServerVersion}}"
INSPECT="buildx inspect"
DUD="buildx du --builder default"
DUC="buildx du --builder fake-builder"
PRD="buildx prune --builder default --force --filter until=23h"
PRC="buildx prune --builder fake-builder --force --filter until=23h"
size_of() { cat "$calls.size.$1" 2>/dev/null || echo untouched; }

# janitor <path-dirs> <args...>: everything else pinned to the fixture.
janitor() {
  local p="$1"; shift
  : > "$calls"; rm -f "$calls.size.default" "$calls.size.fake-builder" "$calls.size.other"
  env -u NJ_DOCKER_BUILDER_PRUNE -u NJ_BUS_DIR -u DOCKER_HOST \
    PATH="$p" FAKE_DOCKER_LOG="$calls" GH_ATTACHMENTS_DIR="$scratch/attach" NJ_ARCHIVE_DAYS=0 \
    "${JENV[@]}" "$BASH" "$repo/bin/night-janitor.sh" "$@" 2>&1
}
WITH="$scratch/fake:$scratch/sane"
WITHOUT="$scratch/sane"
# calls_are <expected lines...>: the fake's log is exactly these invocations, in order.
calls_are() { [ "$(cat "$calls")" = "$(printf '%s\n' "$@")" ]; }
# Over EVERY docker invocation of the whole test file (all cases), not just the last run.
allowed_only() { ! /usr/bin/grep -qvxE 'info --format \{\{\.ServerVersion\}\}|buildx inspect|buildx du --builder (default|fake-builder)|buildx prune --builder (default|fake-builder) --force --filter until=23h' "$calls.all"; }

# start_build <argv0> <args...>: a real process whose /proc cmdline is <argv0> <args...> plus
# the bash -c script. The trailing `:` keeps bash from exec'ing sleep (which would drop argv).
start_build() {
  local a0="$1" c; shift
  ( exec -a "$a0" bash -c 'sleep 120; :' "$@" ) &
  local p=$!; pids+=("$p")
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    c="$( { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null )"
    /usr/bin/grep -qF -- "$a0 -c" <<<"$c" && break; sleep 0.1
  done
  BUILD_PID="$p"
}
stop_build() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
cmdline_is() { [ "$(tr '\0' ' ' < "/proc/$1/cmdline")" = "$2 " ]; }

# 1. off by default ------------------------------------------------------------------
JENV=()
out="$(janitor "$WITH" --apply)"
check "off by default: no docker call at all" "$([ ! -s "$calls" ]; echo $?)"
check "off by default: says skipped" "$(/usr/bin/grep -q 'docker-cache: NJ_DOCKER_BUILDER_PRUNE unset, skipped' <<<"$out"; echo $?)"
JENV=(NJ_DOCKER_BUILDER_PRUNE=yes)
out="$(janitor "$WITH" --apply)"
check "only the value 1 enables (yes -> no call)" "$([ ! -s "$calls" ]; echo $?)"

JENV=(NJ_DOCKER_BUILDER_PRUNE=1)
# 2. POSITIVE CONTROL: apply, nothing building -> one prune per builder, builder named in the argv
out="$(janitor "$WITH" --apply)"; rc=$?
check "positive control: janitor rc 0" "$rc"
check "positive control: full argv log, --builder on every du and prune" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$PRD" "$DUD" "$DUC" "$PRC" "$DUC"; echo $?)"
check "positive control: prune argv exactly '$PRC' once" "$([ "$(/usr/bin/grep -c -x -F -- "$PRC" "$calls")" -eq 1 ]; echo $?)"
check "positive control: the CURRENT builder's cache is gone (fake-builder 0B)" "$([ "$(size_of fake-builder)" = 0B ]; echo $?)"
check "positive control: the default builder's cache is gone (default 0B)" "$([ "$(size_of default)" = 0B ]; echo $?)"
check "positive control: fake-builder line: reclaimed 3.6GB, after 0B" "$(/usr/bin/grep -q 'builder fake-builder prune rc=0, reclaimed 3.6GB, cache after 0B (reclaimable 0B)' <<<"$out"; echo $?)"
check "positive control: default line: reclaimed 1.2GB, after 0B" "$(/usr/bin/grep -q 'builder default prune rc=0, reclaimed 1.2GB, cache after 0B (reclaimable 0B)' <<<"$out"; echo $?)"
check "positive control: before sizes logged per builder" "$(/usr/bin/grep -q 'builder fake-builder cache before 3.6GB' <<<"$out" && /usr/bin/grep -q 'builder default cache before 1.2GB' <<<"$out"; echo $?)"
check "positive control: janitor.log has the prune lines" "$([ "$(/usr/bin/grep -c 'docker-cache: builder .* prune rc=0' "$TEAM_DIR/janitor.log")" -ge 2 ]; echo $?)"
check "positive control: rest of the janitor ran (done line)" "$(/usr/bin/grep -q 'night-janitor \[APPLY\] done' <<<"$out"; echo $?)"
echo "    --- positive control, fake docker argv log:"; sed 's/^/    | /' "$calls"
echo "    --- positive control, janitor docker-cache lines:"; /usr/bin/grep 'docker-cache' <<<"$out" | sed 's/^/    | /'

# 2a. the legacy "Total reclaimed space:" wording is still parsed
JENV=(NJ_DOCKER_BUILDER_PRUNE=1 FAKE_PRUNE_FORMAT=legacy)
out="$(janitor "$WITH" --apply)"
check "legacy prune wording: reclaimed 3.6GB parsed" "$(/usr/bin/grep -q 'builder fake-builder prune rc=0, reclaimed 3.6GB, cache after 0B' <<<"$out"; echo $?)"
check "legacy prune wording: reclaimed 1.2GB parsed" "$(/usr/bin/grep -q 'builder default prune rc=0, reclaimed 1.2GB, cache after 0B' <<<"$out"; echo $?)"
check "no prune line says reclaimed unknown (both wordings)" "$(! /usr/bin/grep -q 'reclaimed unknown' "$TEAM_DIR/janitor.log"; echo $?)"
check "the until value carries the why (parent last-used bump) next to it" "$(near="$(/usr/bin/grep -B6 -F 'NJ_PRUNE_ARGS=(--force --filter until=23h)' "$repo/bin/night-janitor.sh")"; /usr/bin/grep -qi 'last-used' <<<"$near"; echo $?)"
JENV=(NJ_DOCKER_BUILDER_PRUNE=1)

# 2b. current builder IS default: one target, no second prune
JENV=(NJ_DOCKER_BUILDER_PRUNE=1 FAKE_CURRENT=default)
out="$(janitor "$WITH" --apply)"
check "current = default: one prune, on default" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$PRD" "$DUD"; echo $?)"
# 2c. a current-builder name that is not a plain name never reaches an argv
JENV=(NJ_DOCKER_BUILDER_PRUNE=1 'FAKE_CURRENT=x --all')
out="$(janitor "$WITH" --apply)"
check "odd builder name: ignored, default only" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$PRD" "$DUD"; echo $?)"
check "odd builder name: one line says so" "$(/usr/bin/grep -q 'current builder name not a plain name, ignored' <<<"$out"; echo $?)"
JENV=(NJ_DOCKER_BUILDER_PRUNE=1 FAKE_CURRENT=-x)
out="$(janitor "$WITH" --apply)"
check "builder name starting with '-': ignored, default only" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$PRD" "$DUD"; echo $?)"
JENV=(NJ_DOCKER_BUILDER_PRUNE=1)

# 3. dry run: read-only calls only, never a prune ------------------------------------
out="$(janitor "$WITH")"
check "dry run: argv log is info, inspect, du per builder only (no prune)" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$DUC"; echo $?)"
check "dry run: prints what it would run and the size, per builder" "$(/usr/bin/grep -q "would run: docker $PRC (builder fake-builder cache now 3.6GB" <<<"$out" && /usr/bin/grep -q "would run: docker $PRD (builder default cache now 1.2GB" <<<"$out"; echo $?)"
check "dry run: both caches untouched" "$([ "$(size_of default)" = untouched ] && [ "$(size_of fake-builder)" = untouched ]; echo $?)"

# 4. a running build skips the prune, naming the process ----------------------------
for spec in "docker buildx build -t x ." "docker compose -f c.yml build" "docker build -t x ." \
            "/usr/bin/docker build ." "docker -c remote build ." "docker-compose compose build" \
            "docker-buildx buildx bake" "docker buildx bake" "docker compose up -d --build" \
            "docker-compose up --build web" "docker compose watch" \
            "docker buildx b -t x ." "docker-buildx buildx b ." "docker compose up --build=true" \
            "docker compose run --rm web" "docker-compose run web" "docker compose -f c.yml create --build" \
            "docker build --build-arg ARG_MARKER=notlogged42 -t x ."; do
  read -r -a sv <<<"$spec"
  start_build "${sv[0]}" "${sv[@]:1}"
  pre="$(cmdline_is "$BUILD_PID" "${sv[0]} -c sleep 120; : ${sv[*]:1}"; echo $?)"
  check "precondition: /proc shows '$spec'" "$pre"
  out="$(janitor "$WITH" --apply)"
  check "build '$spec': no prune issued" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$DUC"; echo $?)"
  check "build '$spec': SKIPPED line names pid $BUILD_PID and argv0" "$(/usr/bin/grep -q "docker-cache: SKIPPED, build running: pid $BUILD_PID ${sv[0]##*/} \.\.\. " <<<"$out"; echo $?)"
  check "build '$spec': rest of argv not logged (no secrets)" "$(! /usr/bin/grep -q notlogged42 <<<"$out" && ! /usr/bin/grep -q notlogged42 "$TEAM_DIR/janitor.log"; echo $?)"
  stop_build "$BUILD_PID"
done

# 5. not a build, or not docker: the prune still runs ---------------------------------
start_build docker ps -a; p1="$BUILD_PID"
start_build grep -F "docker build" x; p2="$BUILD_PID"
start_build bash "docker buildx build ."; p3="$BUILD_PID"
start_build mydocker build .; p4="$BUILD_PID"
start_build docker run alpine true; p5="$BUILD_PID"
check "precondition: 5 non-build processes alive" "$(for p in $p1 $p2 $p3 $p4 $p5; do [ -r "/proc/$p/cmdline" ] || exit 1; done; echo 0)"
out="$(janitor "$WITH" --apply)"
check "docker ps / a grep for 'docker build' / mydocker / docker run (not compose): prune runs" "$(calls_are "$INFO" "$INSPECT" "$DUD" "$PRD" "$DUD" "$DUC" "$PRC" "$DUC"; echo $?)"
for p in $p1 $p2 $p3 $p4 $p5; do stop_build "$p"; done

# 5b. a process that vanishes mid-scan prints nothing to stderr. A real vanish is a
# race, so this pins the mechanism: the old form leaks, the janitor's form does not, and the janitor
# uses the latter.
check "vanish: old form leaks 'No such file' (control)" "$( e="$( { "$BASH" -c 'mapfile -d "" -t av < /proc/999999999/cmdline 2>/dev/null || true'; } 2>&1 )"; /usr/bin/grep -q 'No such file' <<<"$e"; echo $?)"
check "vanish: braced form is silent" "$( e="$( { "$BASH" -c '{ mapfile -d "" -t av < /proc/999999999/cmdline; } 2>/dev/null || true'; } 2>&1 )"; [ -z "$e" ]; echo $?)"
check "vanish: the janitor reads cmdline only in the braced form" "$(
  [ "$(/usr/bin/grep -c -F '{ mapfile -d '"''"' -t av < "$d/cmdline"; } 2>/dev/null || continue' "$repo/bin/night-janitor.sh")" -eq 1 ] &&
  [ "$(/usr/bin/grep -c 'cmdline' "$repo/bin/night-janitor.sh" | tr -d ' ')" -ge 1 ] &&
  ! /usr/bin/grep -qE '^[^#{]*mapfile[^}]*/cmdline"? 2>' "$repo/bin/night-janitor.sh"; echo $?)"

# 6. docker missing / daemon unreachable: one line, janitor continues -----------------
out="$(janitor "$WITHOUT" --apply)"; rc=$?
check "docker missing: one line" "$([ "$(/usr/bin/grep -c 'docker-cache: docker not installed, skipped' <<<"$out")" -eq 1 ]; echo $?)"
check "docker missing: janitor completes rc 0" "$([ "$rc" -eq 0 ] && /usr/bin/grep -q 'done' <<<"$out"; echo $?)"
check "docker missing: the fake was not reachable either" "$([ ! -s "$calls" ]; echo $?)"
JENV=(NJ_DOCKER_BUILDER_PRUNE=1 FAKE_DOCKER_DAEMON=down)
out="$(janitor "$WITH" --apply)"; rc=$?
check "daemon down: only the info probe was called" "$(calls_are "$INFO"; echo $?)"
check "daemon down: one line, janitor completes rc 0" "$([ "$rc" -eq 0 ] && [ "$(/usr/bin/grep -c 'docker daemon unreachable, skipped' <<<"$out")" -eq 1 ] && /usr/bin/grep -q 'done' <<<"$out"; echo $?)"

# 7. argument guard over every run above is in each calls_are; one more sweep for safety:
check "argument guard: every docker call of every case is info/inspect/du/prune with --builder" "$(allowed_only; echo $?)"
check "argument guard: the cumulative log saw the prunes" "$([ "$(/usr/bin/grep -c -x -F -- "$PRC" "$calls.all")" -ge 2 ]; echo $?)"
check "argument guard: no 'builder prune' (pinned to default) anywhere" "$(! /usr/bin/grep -q '^builder ' "$calls.all"; echo $?)"
check "argument guard: the script text holds one prune argv and no forbidden verb" "$(
  s="$repo/bin/night-janitor.sh"
  code="$(sed '/^[[:space:]]*#/d' "$s")"
  [ "$(/usr/bin/grep -c -F 'NJ_PRUNE_ARGS=(--force --filter until=23h)' <<<"$code")" -eq 1 ] &&
  # Every line that can execute docker (log text, the argv0 case list and command -v aside)
  # is one of exactly four calls; the one prune passes --builder and the constant NJ_PRUNE_ARGS.
  calls_in_code="$(/usr/bin/grep -E '\bdocker\b' <<<"$code" | /usr/bin/grep -vE '^\s*(note |.*\bnote ")|case "\$a0" in docker\||command -v docker|"\$a0" = docker-compose' | sed -E 's/.*(timeout [0-9]+ docker [^)]*).*/\1/; s/ *[0-9]*>.*//')"
  [ "$calls_in_code" = "$(printf '%s\n' 'timeout 120 docker buildx du --builder "$1"' 'timeout 60 docker buildx inspect' 'timeout 30 docker info --format '"'"'{{.ServerVersion}}'"'"'' 'timeout 900 docker buildx prune --builder "$t" "${NJ_PRUNE_ARGS[@]}"')" ] &&
  ! /usr/bin/grep -qE 'system +prune|image +prune|volume +prune|network +prune|container +prune|--all|\brmi\b|docker +(rm|kill|stop|volume|network|image|system +prune)' <<<"$code"
  echo $?)"

echo
echo "night-janitor-docker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

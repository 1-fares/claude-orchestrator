#!/usr/bin/env bash
# `printf '%s' "$out" | grep -q X` under `set -o pipefail` is a RACE.
#
# bash line-buffers a builtin's stdout, so printf writes multi-line output ONE write() PER LINE. grep -q
# exits on its first match; if that is before printf's last write, printf takes SIGPIPE (141) and
# pipefail turns the pipeline -- and so the assertion -- false. It fires only when the scheduler lets
# grep finish between two of printf's writes, i.e. under suite load: a liveness suite failed 4 runs in
# 36 under 6-way load, and 21 of its 23 assertions fail deterministically once the output is long
# enough (20000 filler lines). It fails BOTH ways: an `grep -q X && no || ok` assertion reads a SIGPIPE
# as a PASS.
#
# The fix is a here-string -- `grep -q X <<<"$out"` -- no pipe, no SIGPIPE, same semantics.
#
# RATCHET: a test file listed in pipefail-grep-q.allow may still have the pattern; a file NOT on that
# list must not gain it (new instances fail here), and a listed file that no longer has it must leave
# the list (so the list only shrinks). Converting a listed file = fix it, delete its line.
# Only a line that IS a comment is skipped, so a `#` inside quotes before the pipe (a tmux format,
# `-F '#{window_name}' | grep -qx`) does not hide it.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${PGQ_TESTS_DIR:-$repo/bin/tests}"
ALLOW="${PGQ_ALLOW:-$repo/bin/tests/pipefail-grep-q.allow}"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
[ -f "$ALLOW" ] || { echo "  FAIL allowlist missing at $ALLOW"; exit 1; }

# Matches `| grep -q`, `| /usr/bin/grep -Fq`, `| egrep --quiet|--silent`, `| command grep -q`, `| LC_ALL=C grep -q`,
# `| { grep -q ...; }` (any path, any flag order within the pipe segment; not `||`, and grep's args stop at an
# UNQUOTED ; & )). A pipe that ends one line (`producer |` or `producer | \`) with the grep on the next is joined
# first (pgq_lines). KNOWN LIMITS: `| xargs grep -q` is not this race (grep reads files, not the pipe);
# `| sh -c 'grep -q ..'`, a grep behind a function or alias, and a match split by a $'..' string are not seen.
PGQ_RE='([^|]|^)\|[[:space:]]*(\{[[:space:]]*)?((command|env)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]|]*/)?e?grep[[:space:]]+(('"'"'[^'"'"']*'"'"'|"[^"]*"|[^|;&)'"'"'"])*[[:space:]])?(-[a-zA-Z]*q[a-zA-Z]*|--quiet|--silent)([[:space:]]|$)'
# A line that only QUOTES such a pipeline (fixture text in a string) carries `# pgq: not a pipe`.
# pgq_lines <file>: every pipe-into-grep-q line, trimmed, one per line (no -q after a pipe here).
# A line ending in `|` or `| \` is printed joined to its next line (that pair is the pipe), and every
# line once as it is.
pgq_lines() {
    awk '{ if (prev != "") print prev " " $0; prev = ""; print }
         /[^|]\|[[:space:]]*\\?[[:space:]]*$/ { p = $0; sub(/\\?[[:space:]]*$/, "", p); prev = p }' "$1" \
    | /usr/bin/grep -E "$PGQ_RE" | /usr/bin/grep -vE '^[[:space:]]*#' | /usr/bin/grep -v 'pgq: not a pipe' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
PF_RE='^[^#]*o[[:space:]]+pipefail'   # `set -o  pipefail` (2 spaces, a tab) is in scope too
has_pattern() { /usr/bin/grep -q -E "$PF_RE" "$1" || return 1
    [ -n "$(pgq_lines "$1")" ]; }

scanned=0; new=""; stale=""
for f in "$DIR"/*.sh; do
    [ -f "$f" ] || continue
    scanned=$((scanned+1))
    b="${f##*/}"
    listed=0; /usr/bin/grep -qxF "$b" "$ALLOW" && listed=1
    if has_pattern "$f"; then [ "$listed" = 1 ] || new="$new $b"
    else [ "$listed" = 1 ] && stale="$stale $b"; fi
done
# A scan of nothing would pass every check below; demand a real population.
[ "$scanned" -ge 10 ] && ok "scanned $scanned test files" || no "scanned only $scanned files under $DIR"
[ -z "$new" ] && ok "no unlisted test pipes into grep -q under pipefail" \
    || no "pipe into grep -q under pipefail (use grep -q X <<<\"\$out\"):$new"
[ -z "$stale" ] && ok "allowlist has no fixed files left on it" \
    || no "fixed -- remove from $(basename "$ALLOW"):$stale"

printf '\npipefail-grep-q-ratchet: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

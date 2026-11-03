#!/usr/bin/env bash
# The pipefail-grep-q ratchet also scans shell sources outside bin/tests.
# Drives bin/tests/pipefail-grep-q-ratchet.test.sh against fixture source trees (PGQ_SRC_ROOT /
# PGQ_SRC_ALLOW), with the real bin/tests and its allowlist, and checks each rule both ways:
#   - a pipefail daemon with `printf | grep -q` goes RED (the old pattern), and passes once allow-listed;
#   - a bin/lib library is in scope with no pipefail line of its own (it is sourced into daemons);
#   - a file with no pipefail, outside bin/lib, is not;
#   - a quoted `#` before the pipe (`-F '#{window_name}' | grep -qx`) no longer hides it;
#   - a comment line is not a pipe;
#   - an allowlist line whose source line is gone is stale (RED); a second copy of an allowed line is new (RED);
#   - an extensionless bash script (bin/hooks/pre-push) is scanned.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RATCHET="${PGQ_RATCHET:-$repo/bin/tests/pipefail-grep-q-ratchet.test.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; fail=$((fail+1)); }

# fixture: a clean tree of 10 shell files, 6 under pipefail, no pipe into grep -q anywhere.
fresh() {
  rm -rf "$T/src"; mkdir -p "$T/src/bin/lib" "$T/src/bin/hooks" "$T/src/bin/tests" "$T/src/tests"
  for i in 1 2 3 4 5; do printf '#!/usr/bin/env bash\nset -uo pipefail\ngrep -q x <<<"$out" && echo y\n' > "$T/src/bin/d$i.sh"; done
  printf '#!/usr/bin/env bash\ngrep -q x <<<"$t"\n' > "$T/src/bin/lib/clean.sh"
  for i in 1 2 3 4; do printf '#!/usr/bin/env bash\necho plain\n' > "$T/src/tests/p$i.sh"; done
  : > "$T/allow"
}
run() { out="$(PGQ_SRC_ROOT="$T/src" PGQ_SRC_ALLOW="$T/allow" bash "$RATCHET" 2>&1)"; rc=$?; }
add() { printf '%s\n' "$2" >> "$T/src/$1"; }

fresh; run
[ "$rc" = 0 ] && ok "clean fixture tree passes" || no "clean fixture tree failed (rc $rc)" "$out"
/usr/bin/grep -q 'scanned 10 shell sources, 6 under pipefail' <<<"$out" \
  && ok "population counted: 10 sources, 6 in scope (5 pipefail + 1 lib)" || no "population miscounted" "$(/usr/bin/grep scanned <<<"$out")"

PIPE='if printf '"'"'%s'"'"' "$pane" | grep -qE "esc to interrupt"; then echo busy; fi'  # pgq: not a pipe
fresh; add bin/d1.sh "$PIPE"; run
[ "$rc" = 1 ] && /usr/bin/grep -qF "bin/d1.sh" <<<"$out" \
  && ok "RED: a pipefail daemon piping printf into grep -q (the old pattern), named" || no "old pattern in a daemon not caught (rc $rc)" "$out"
printf 'bin/d1.sh\t%s\tfixture reason\n' "$PIPE" >> "$T/allow"; run
[ "$rc" = 0 ] && ok "the same line passes once allow-listed with a reason" || no "allow-listed line still fails (rc $rc)" "$out"
add bin/d1.sh "$PIPE"; run
[ "$rc" = 1 ] && ok "RED: a second copy of an allowed line is new (multiset)" || no "duplicate of an allowed line passed" "$out"

fresh; printf 'bin/d2.sh\t%s\tfixture reason\n' "$PIPE" >> "$T/allow"; run
[ "$rc" = 1 ] && /usr/bin/grep -q 'remove from allow' <<<"$out" && /usr/bin/grep -qF 'bin/d2.sh' <<<"$out" \
  && ok "RED: an allowlist line whose source line is gone is stale" || no "stale allowlist line not reported (rc $rc)" "$out"

fresh; add bin/lib/clean.sh "$PIPE"; run
[ "$rc" = 1 ] && /usr/bin/grep -qF 'bin/lib/clean.sh' <<<"$out" \
  && ok "RED: a bin/lib library is in scope without its own pipefail line" || no "library pipe not caught (rc $rc)" "$out"

fresh; add tests/p1.sh "$PIPE"; run
[ "$rc" = 0 ] && ok "a non-library file with no pipefail is out of scope" || no "no-pipefail file flagged (rc $rc)" "$out"

fresh; add bin/d3.sh "tmux list-windows -t \"\$s\" -F '#{window_name}' 2>/dev/null | grep -qx orchestrator"; run  # pgq: not a pipe
[ "$rc" = 1 ] && /usr/bin/grep -qF 'bin/d3.sh' <<<"$out" \
  && ok "RED: a quoted # before the pipe no longer hides it (tmux -F '#{...}')" || no "hash-before-pipe line missed (rc $rc)" "$out"

fresh; add bin/d4.sh "  # an example: printf '%s' \"\$x\" | grep -q y"; run  # pgq: not a pipe
[ "$rc" = 0 ] && ok "a comment line is not a pipe" || no "comment line flagged (rc $rc)" "$out"

fresh; printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$PIPE" > "$T/src/bin/hooks/pre-push"; run
[ "$rc" = 1 ] && /usr/bin/grep -qF 'bin/hooks/pre-push' <<<"$out" \
  && ok "RED: an extensionless bash script is scanned" || no "extensionless script missed (rc $rc)" "$out"

fresh; mkdir -p "$T/src/bin/tests"; printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$PIPE" > "$T/src/bin/tests/zz.test.sh"; run
[ "$rc" = 0 ] && ok "bin/tests under the source root is left to the test-file scan" || no "source scan entered bin/tests (rc $rc)" "$out"

# Each form below must go RED in a pipefail daemon.
red_form() {  # red_form <label> <line...>: plant the lines in bin/d5.sh, expect rc 1 naming it
  local label="$1"; shift; fresh; for l in "$@"; do add bin/d5.sh "$l"; done; run
  [ "$rc" = 1 ] && /usr/bin/grep -qF 'bin/d5.sh' <<<"$out" && ok "RED: $label" || no "$label not caught (rc $rc)" "$out"
}
red_form "grep --silent"            'printf "%s" "$p" | grep --silent busy && echo y'          # pgq: not a pipe
red_form "command grep -q"          'printf "%s" "$p" | command grep -q busy && echo y'        # pgq: not a pipe
red_form "LC_ALL=C grep -q"         'printf "%s" "$p" | LC_ALL=C grep -q busy && echo y'       # pgq: not a pipe
red_form "{ grep -q ...; }"         'printf "%s" "$p" | { grep -q busy; } && echo y'           # pgq: not a pipe
red_form "pipe continued with a backslash" 'if printf "%s" "$p" | \' '   grep -q busy; then echo y; fi'  # pgq: not a pipe
red_form "pipe ending a line with |" 'if printf "%s" "$p" |' '   grep -q busy; then echo y; fi'  # pgq: not a pipe
red_form "the pgq marker is not honoured in a source" 'printf "%s" "$p" | grep -q busy  # pgq: not a pipe'
for sep in '  ' $'\t'; do
  fresh; printf '#!/usr/bin/env bash\nset -o%spipefail\nprintf "%%s" "$p" | grep -q busy\n' "$sep" > "$T/src/tests/p1.sh"; run  # pgq: not a pipe
  [ "$rc" = 1 ] && /usr/bin/grep -qF 'tests/p1.sh' <<<"$out" && ok "RED: set -o<$(printf '%q' "$sep")>pipefail is in scope" \
    || no "set -o with $(printf '%q' "$sep") before pipefail fell out of scope (rc $rc)" "$out"
done
# Not this race, by design: xargs runs grep on FILES, the producer is not cut off by grep's exit.
fresh; add bin/d5.sh 'printf "%s\n" a b | xargs grep -q busy && echo y'; run   # pgq: not a pipe
[ "$rc" = 0 ] && ok "| xargs grep -q is a known limit, not flagged" || no "xargs form flagged (rc $rc)" "$out"

# The live tree, with the real allowlist, passes (the population checks keep this from being vacuous).
out="$(bash "$RATCHET" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the live tree passes with the real allowlist" || no "live tree fails the ratchet (rc $rc)" "$out"

printf '\npipefail-grep-q-src-ratchet: %d pass, %d fail\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1

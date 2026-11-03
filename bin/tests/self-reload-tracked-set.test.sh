#!/usr/bin/env bash
# self-reload-tracked-set.test.sh: every self-reloading daemon must TRACK every file it SOURCES, transitively.
# self_reload_init hashes only the files it is given, so a sourced lib missing from that list is INERT in the
# running daemon until a manual restart: a committed fix that never runs. The python self-reloaders track only
# their own file, which is complete only while they import nothing from the repo at module level; that is
# asserted too.
#
# Discovery is by grep (count, do not sample): every bin/ file outside bin/lib and bin/tests that calls
# self_reload_init, and every bin/ .py with _self_reload_if_changed or SELF_RELOAD_MIN_AGE. A new daemon, or a
# new sourced file not named below, turns this red until it is added, which is the point.
# Daemons: api-watchdog chrome-supervisor compaction-watchdog disk-tmp-watchdog host-ram-watchdog observer
#   permission-mode-watchdog tmux-watchdog watchdog bus-inbox
# Sourced files: team-env tmux-input tmux-submit notify self-reload status-hook watchdog-detect compaction-detect
#   disk-tmp host-ram host-verdict observer-nudge project.conf
# Run against another checkout: RELOAD_TREE_UNDER_TEST=<dir>.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tree="${RELOAD_TREE_UNDER_TEST:-$repo}"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

EXPECTED_BASH="bin/api-watchdog.sh bin/chrome-supervisor.sh bin/compaction-watchdog.sh bin/disk-tmp-watchdog.sh
bin/host-ram-watchdog.sh bin/observer.sh bin/permission-mode-watchdog.sh bin/tmux-watchdog.sh bin/watchdog.sh"
EXPECTED_PY="bin/bus-inbox.py"
# <daemon>|<sourced file>|why it need not be tracked. Only a file read AGAIN on every use belongs here.
ALLOW="bin/tmux-watchdog.sh|project.conf|sourced inside ensure_intake_poller on every call, so a change is read at the next call"

audit_py="$(mktemp)"; allow_f="$(mktemp)"; fx="$(mktemp -d)"
trap 'rm -rf "$audit_py" "$allow_f" "$fx"' EXIT
cat > "$audit_py" <<'PY'
import os, re, sys
# usage: audit.py <repo> <allow-file> <daemon>...   prints one line per finding: GAP|UNRESOLVED|MISSING|SOURCED <...>
repo = os.path.abspath(sys.argv[1]); allow = set()
for line in open(sys.argv[2]):
    if line.strip():
        d, f, _ = line.rstrip('\n').split('|', 2); allow.add((d, f))
# The path shapes this engine uses in `.`/`source` lines and in self_reload_init. Anything else is UNRESOLVED and
# fails: extend this list (or the allow list) on purpose rather than let a new shape go unchecked.
FORMS = [
    (re.compile(r'"\$\(cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/lib" && pwd\)/([^"]+)"'),
     lambda f, m: os.path.join(os.path.dirname(f), 'lib', m.group(1))),
    (re.compile(r'"\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/([^"]+)"'),
     lambda f, m: os.path.join(os.path.dirname(f), m.group(1))),
    (re.compile(r'"\$\{?(?:repo|REPO|TEAM_REPO)\}?/([^"]+)"'),
     lambda f, m: os.path.join(repo, m.group(1))),
]
SRC = re.compile(r'^\s*(?:\.|source)\s+(["$/].*)$')   # a path argument; prose such as "source of ..." is not one

def resolve(f, expr):
    for rx, fn in FORMS:
        m = rx.match(expr)
        if m:
            return os.path.normpath(fn(f, m)), m.end()
    return None, 0

def closure(f):
    seen, stack = {}, [f]
    while stack:
        cur = stack.pop()
        for n, line in enumerate(open(cur, encoding='utf-8', errors='replace'), 1):
            m = SRC.match(line)
            if not m:
                continue
            p, _ = resolve(cur, m.group(1))
            if p is None:
                print('UNRESOLVED %s:%d %s' % (os.path.relpath(cur, repo), n, m.group(1).strip()))
                continue
            if p not in seen:
                seen[p] = '%s:%d' % (os.path.relpath(cur, repo), n)
                if os.path.isfile(p):
                    stack.append(p)
    return seen

def tracked(f):
    text = open(f, encoding='utf-8').read().replace('\\\n', ' ')
    m = re.search(r'^\s*self_reload_init\s+"\$0"(.*)$', text, re.M)
    got, rest = set(), (m.group(1).strip() if m else None)
    if rest is None:
        print('UNRESOLVED %s: no self_reload_init "$0" line' % os.path.relpath(f, repo)); return got
    while rest and not rest.startswith('#'):
        p, end = resolve(f, rest)
        if p is None:
            tok = rest.split()[0]; print('UNRESOLVED %s: tracked arg %s' % (os.path.relpath(f, repo), tok))
            rest = rest[len(tok):].lstrip(); continue
        got.add(p); rest = rest[end:].lstrip()
    return got

for d in sys.argv[3:]:
    f = os.path.join(repo, d)
    cl, tr = closure(f), tracked(f)
    for p in sorted(tr):
        if not os.path.isfile(p):
            print('MISSING %s tracks %s, which does not exist' % (d, os.path.relpath(p, repo)))
    for p in sorted(cl):
        rel = os.path.relpath(p, repo)
        print('SOURCED %s %s' % (d, rel))
        if p != f and p not in tr and (d, rel) not in allow:
            print('GAP %s sources %s (%s) but self_reload_init does not track it' % (d, rel, cl[p]))
PY

printf '%s\n' "$ALLOW" > "$allow_f"

echo "1. discovery: the daemon set is exactly the expected one (count, do not sample)"
found_bash="$(cd "$tree" && grep -rlE '^[[:space:]]*self_reload_init[[:space:]]' bin --include='*.sh' | grep -vE '^bin/(tests|lib)/' | sort | tr '\n' ' ')"
want_bash="$(tr ' \n' '\n\n' <<<"$EXPECTED_BASH" | grep . | sort | tr '\n' ' ')"
[ "$found_bash" = "$want_bash" ] && ok "9 bash self-reloaders, as listed" || no "bash self-reloaders differ: found [$found_bash] want [$want_bash]"
found_py="$(cd "$tree" && grep -rlE '_self_reload_if_changed|SELF_RELOAD_MIN_AGE' bin --include='*.py' | grep -vE '^bin/(tests|lib)/' | sort | tr '\n' ' ')"
want_py="$(tr ' ' '\n' <<<"$EXPECTED_PY" | sort | tr '\n' ' ')"
[ "$found_py" = "$want_py" ] && ok "1 python self-reloader, as listed" || no "python self-reloaders differ: found [$found_py] want [$want_py]"

echo "2. every bash daemon tracks everything it sources, transitively"
# shellcheck disable=SC2086
res="$(python3 "$audit_py" "$tree" "$allow_f" $EXPECTED_BASH)"
gaps="$(grep '^GAP ' <<<"$res")"; unres="$(grep '^UNRESOLVED ' <<<"$res")"; miss="$(grep '^MISSING ' <<<"$res")"
[ -z "$gaps" ] && ok "no sourced file is untracked" || no "$(grep -c . <<<"$gaps") gap(s):
$gaps"
[ -z "$unres" ] && ok "every source line and tracked arg resolves" || no "unresolved (extend FORMS or ALLOW on purpose):
$unres"
[ -z "$miss" ] && ok "every tracked file exists" || no "$miss"
nsrc="$(grep -c '^SOURCED ' <<<"$res")"
[ "$nsrc" -ge 40 ] && ok "floor: $nsrc daemon->file edges audited (>= 40; an audit that sees nothing agrees with everything)" \
  || no "only $nsrc sourced edges seen: the parser went blind"

echo "3. every sourced file is named in this test's header"
self="$here/$(basename "${BASH_SOURCE[0]}")"
unnamed=""
for f in $(grep '^SOURCED ' <<<"$res" | awk '{print $3}' | sort -u); do
  b="$(basename "$f")"; key="${b%.sh}"
  grep -qF -- "$key" "$self" || unnamed="$unnamed $f"
done
[ -z "$unnamed" ] && ok "all sourced files are named in the header" || no "add to the 'Sourced files' header:$unnamed"

echo "4. python self-reloaders import nothing from the repo at module level (they track only __file__)"
for p in $EXPECTED_PY; do
  out="$(python3 - "$tree/$p" <<'PY'
import ast, sys
src = open(sys.argv[1]).read(); t = ast.parse(src); std = set(sys.stdlib_module_names) | {'__future__'}
bad = []
for n in ast.walk(t):
    if isinstance(n, ast.Import):
        bad += [a.name for a in n.names if a.name.split('.')[0] not in std]
    elif isinstance(n, ast.ImportFrom) and n.module and n.level == 0 and n.module.split('.')[0] not in std:
        bad.append(n.module)
    elif isinstance(n, ast.ImportFrom) and n.level:
        bad.append('.' * n.level + (n.module or ''))
DYN = {'spec_from_file_location', 'import_module', 'run_path', 'run_module', '__import__'}
for n in t.body:   # module level only: a load inside a function is redone on every call
    for c in ast.walk(n):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            break
        if isinstance(c, ast.Call):
            fn = c.func.attr if isinstance(c.func, ast.Attribute) else getattr(c.func, 'id', '')
            if fn in DYN or (fn == 'insert' and 'sys.path' in ast.unparse(c.func)):
                bad.append('line %d: %s' % (c.lineno, ast.unparse(c)[:80]))
print(' '.join(bad))
PY
)"
  [ -z "$out" ] && ok "$p: stdlib only, no module-level load from the repo" || no "$p loads repo code it does not track: $out"
done

echo "5. control: a fixture daemon that sources an untracked lib IS reported (this suite can go red)"
mkdir -p "$fx/bin/lib"
printf '%s\n' '#!/usr/bin/env bash' 'repo=x' '. "$repo/bin/lib/a.sh"' '. "$repo/bin/lib/self-reload.sh"' \
  'self_reload_init "$0" "$repo/bin/lib/a.sh" \' '  "$repo/bin/lib/self-reload.sh"' > "$fx/bin/d.sh"
printf '%s\n' '. "$(dirname "${BASH_SOURCE[0]}")/b.sh"' > "$fx/bin/lib/a.sh"
: > "$fx/bin/lib/b.sh"; : > "$fx/bin/lib/self-reload.sh"
cres="$(python3 "$audit_py" "$fx" /dev/null bin/d.sh)"
grep -q '^GAP bin/d.sh sources bin/lib/b.sh (bin/lib/a.sh:1)' <<<"$cres" && ok "transitive gap b.sh (via a.sh) reported" || no "control missed: $cres"
[ "$(grep -c '^GAP ' <<<"$cres")" = 1 ] && ok "and only that one (the continued self_reload_init line is parsed)" || no "control: $cres"

echo
echo "self-reload-tracked-set: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

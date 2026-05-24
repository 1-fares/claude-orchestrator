#!/usr/bin/env bash
# link-live.sh: every URL in the artifact returns 2xx (or a tolerable 3xx).
# Prefers `lychee` if available (fast, async, markdown-aware); falls back to
# a portable curl loop. Exit 0 if all live, non-zero if any failed.
#
# Usage:
#   bin/gates/link-live.sh <path-or-dir> [--timeout 15] [--exclude REGEX]

set -euo pipefail
target="${1:?usage: link-live.sh <path-or-dir> [--timeout 15] [--exclude REGEX]}"
shift || true
timeout=15; exclude=""
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    --exclude) exclude="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -e "$target" ] || { echo "no such path: $target" >&2; exit 2; }

if command -v lychee >/dev/null; then
  args=(--no-progress --max-concurrency 8 --timeout "$timeout")
  [ -n "$exclude" ] && args+=(--exclude "$exclude")
  exec lychee "${args[@]}" "$target"
fi

# Fallback: extract URLs with python and HEAD each via curl.
command -v python3 >/dev/null || { echo "python3 missing for fallback" >&2; exit 2; }
command -v curl    >/dev/null || { echo "curl missing for fallback" >&2; exit 2; }
urls=$(python3 - "$target" <<'PY'
import sys, os, re
target = sys.argv[1]
files = []
if os.path.isdir(target):
    for r, _, fs in os.walk(target):
        for f in fs:
            if f.endswith((".md",".txt",".rst",".html")): files.append(os.path.join(r,f))
else:
    files = [target]
pat = re.compile(r"https?://[^\s\)\]<>\"']+")
seen = set()
for f in files:
    try:
        for u in pat.findall(open(f, encoding="utf-8", errors="replace").read()):
            u = u.rstrip(".,;:)]")
            if u not in seen: seen.add(u); print(u)
    except Exception: pass
PY
)
fail=0; total=0
for u in $urls; do
  [ -n "$exclude" ] && echo "$u" | grep -qE "$exclude" && continue
  total=$((total+1))
  code=$(curl -sS -L -o /dev/null -m "$timeout" -w '%{http_code}' --head "$u" 2>/dev/null || echo 000)
  case "$code" in
    2*|3*) ;;
    *) echo "  FAIL $code  $u"; fail=$((fail+1)) ;;
  esac
done
echo "link-live: $((total-fail))/$total live"
[ "$fail" -eq 0 ]

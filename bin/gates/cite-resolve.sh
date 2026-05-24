#!/usr/bin/env bash
# cite-resolve.sh: every citation in the artifact resolves to an entry in the
# bibliography, and every bibliography entry is cited at least once. Deterministic,
# fast, no LLM. Catches dangling refs and orphan sources before any expensive
# LLM-judge gate runs.
#
# Recognised cite markers (configurable via --pattern):
#   - [^key]             (footnote-style)
#   - [@key]             (pandoc-style)
#   - [KEY] / [Key2024]  (bracketed-key, lowercase or capitalised; must start with letter)
#
# The bibliography is parsed loosely: any line beginning with `[key]:`, `[^key]:`,
# `[@key]:`, or `key,` (BibTeX-ish: `@type{key,`) declares an entry. Sub-detection
# is best-effort; for strict BibTeX use `--bib-format bibtex`.
#
# Usage:
#   bin/gates/cite-resolve.sh <artifact> <bibliography> [--pattern REGEX] [--bib-format auto|bibtex|markdown]

set -euo pipefail
art="${1:?usage: cite-resolve.sh <artifact> <bibliography> [opts]}"
bib="${2:?usage: cite-resolve.sh <artifact> <bibliography> [opts]}"
shift 2 || true
pattern='\[\^?@?([A-Za-z][A-Za-z0-9_\-]+)\]'
bib_format=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --pattern) pattern="$2"; shift 2 ;;
    --bib-format) bib_format="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "$art" ] && [ -f "$bib" ] || { echo "missing artifact or bibliography" >&2; exit 2; }

python3 - "$art" "$bib" "$pattern" "$bib_format" <<'PY'
import sys, re
art_p, bib_p, pat, fmt = sys.argv[1:5]
text = open(art_p, encoding="utf-8", errors="replace").read()
bib  = open(bib_p, encoding="utf-8", errors="replace").read()

cites = set(re.findall(pat, text))
entries = set()
if fmt in ("bibtex","auto"):
    for m in re.finditer(r"@\w+\{\s*([A-Za-z][A-Za-z0-9_\-]+)\s*,", bib):
        entries.add(m.group(1))
if fmt in ("markdown","auto"):
    for m in re.finditer(r"^\[\^?@?([A-Za-z][A-Za-z0-9_\-]+)\]:", bib, re.M):
        entries.add(m.group(1))
    # Also accept "- [key] ..." or "- key: ..." as a soft fallback
    for m in re.finditer(r"^[-*]\s*\[([A-Za-z][A-Za-z0-9_\-]+)\]", bib, re.M):
        entries.add(m.group(1))

missing = sorted(cites - entries)
orphans = sorted(entries - cites)
ok = not missing and not orphans
print(f"cite-resolve: {len(cites)} cites, {len(entries)} entries; "
      f"{'OK' if ok else 'FAIL'}")
if missing:
    print("  missing bibliography entries for:")
    for k in missing: print(f"    - {k}")
if orphans:
    print("  orphan bibliography entries (never cited):")
    for k in orphans: print(f"    - {k}")
sys.exit(0 if ok else 1)
PY

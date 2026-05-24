#!/usr/bin/env bash
# office-wellformed.sh: a docx / pptx file opens cleanly under python-docx /
# python-pptx and contains non-trivial content. Catches the "valid-but-empty" /
# "won't open" failure mode.
#
# Usage:
#   bin/gates/office-wellformed.sh <file.docx | file.pptx>

set -euo pipefail
f="${1:?usage: office-wellformed.sh <file.docx|file.pptx>}"
[ -f "$f" ] || { echo "no file: $f" >&2; exit 2; }
ext="${f##*.}"

case "$ext" in
  docx)
    uv run --with python-docx --quiet python - "$f" <<'PY'
import sys
from docx import Document
d = Document(sys.argv[1])
paras = [p.text for p in d.paragraphs if p.text.strip()]
if not paras:
    print("office-wellformed: FAIL (docx opened but has no non-empty paragraphs)"); sys.exit(1)
print(f"office-wellformed: OK ({len(paras)} non-empty paragraphs)")
PY
    ;;
  pptx)
    uv run --with python-pptx --quiet python - "$f" <<'PY'
import sys
from pptx import Presentation
p = Presentation(sys.argv[1])
slides = list(p.slides)
if not slides:
    print("office-wellformed: FAIL (pptx opened but has no slides)"); sys.exit(1)
texts = sum(1 for s in slides for sh in s.shapes if sh.has_text_frame and sh.text_frame.text.strip())
print(f"office-wellformed: OK ({len(slides)} slides, {texts} text shapes)")
PY
    ;;
  *)
    echo "office-wellformed: unsupported extension '$ext' (docx|pptx)" >&2; exit 2 ;;
esac

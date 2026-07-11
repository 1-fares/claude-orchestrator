#!/usr/bin/env bash
# impact-scan.sh: heuristic reverse-dependency / reference finder. Given a file,
# lists source files that import or reference it; given a symbol, lists files that
# mention it (word-boundary). Use to scope a change before editing, or to gauge
# the blast radius of touching a file. Text-match only: same-named symbols in
# unrelated files can appear, so treat the output as a lead, not proof.
#
#   bin/tools/impact-scan.sh <file-path | symbol>
set -uo pipefail

target="${1:-}"
[ -n "$target" ] || { echo "usage: impact-scan.sh <file-path | symbol>" >&2; exit 2; }

USE_RG=0; command -v rg >/dev/null 2>&1 && USE_RG=1
EXC='.git node_modules vendor dist build target .venv __pycache__'

scan() {  # scan <extended-regex> [word]
  local pat="$1" word="${2:-}"
  if [ "$USE_RG" -eq 1 ]; then
    local args=(-n --no-heading -e "$pat")
    [ "$word" = word ] && args=(-nw --no-heading -e "$pat")
    for e in $EXC; do args+=(-g "!$e"); done
    rg "${args[@]}" . 2>/dev/null
  else
    local ex=(); for e in $EXC; do ex+=(--exclude-dir="$e"); done
    if [ "$word" = word ]; then grep -rnwIE "${ex[@]}" -- "$pat" . 2>/dev/null
    else grep -rnIE "${ex[@]}" -- "$pat" . 2>/dev/null; fi
  fi
}

tally() {  # collapse file:line:match -> "count  file", most-referenced first
  awk -F: '{c[$1]++} END{for(f in c) printf "%5d  %s\n", c[f], f}' | sort -rn
}

if [ -f "$target" ]; then
  stem="$(basename "$target")"; stem="${stem%.*}"
  # Escape regex metacharacters: a stem like "a.b" or "c++" would otherwise
  # build a broken or overbroad ERE.
  stem_re="$(printf '%s' "$stem" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')"
  echo "# files that import/reference $target  (module stem: $stem)"
  self="./${target#./}"
  scan "(import|require|include|from|use|#include)[^\n]*\\b${stem_re}\\b" \
    | grep -v -e "^${target}:" -e "^${self}:" | tally
else
  echo "# files referencing symbol '$target'  (word-boundary, heuristic)"
  scan "$target" word | tally | head -60
fi

echo
echo "note: heuristic text match; verify a hit before relying on it."

#!/usr/bin/env bash
# llm-judge.sh: score an artifact against a rubric via an LLM judge, exit 0/1.
#
# The single LLM-judge primitive. Asks the LLM (via `claude -p` headless) to
# return strict JSON {"pass": bool, "score": int 0..5, "summary": str}. Runs K
# times for self-consistency; passes iff a strict majority of runs returned
# pass:true. All raw runs are logged under $TEAM_DIR/audit/<gate>/ so any call
# is replayable.
#
# Usage:
#   bin/gates/llm-judge.sh <artifact> <rubric.md> [--n K] [--gate NAME] [--model MODEL]
#
# The rubric is a plain markdown file describing the criteria; the LLM reads it
# and decides. Keep rubrics small and explicit; tunable per unit via the
# task brief's verify: line.

set -euo pipefail
art=""; rub=""; n=1; gate="llm-judge"; model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --n)     n="$2"; shift 2 ;;
    --gate)  gate="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *)  if [ -z "$art" ]; then art="$1"; else rub="$1"; fi; shift ;;
  esac
done
[ -f "$art" ] && [ -f "$rub" ] || { echo "usage: $0 <artifact> <rubric.md> [opts]" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude CLI missing on PATH" >&2; exit 2; }
command -v jq     >/dev/null || { echo "jq missing on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 missing on PATH" >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/team-env.sh"
audit="$TEAM_DIR/audit/$gate"
mkdir -p "$audit"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
log="$audit/$(basename "$art" | tr / _)-$ts.log"

prompt() {
  cat <<EOF
You are a strict evaluator. Judge the ARTIFACT below against the RUBRIC. Return
ONLY strict JSON, no prose, no markdown fence, in exactly this shape:

{"pass": true, "score": 4, "summary": "one short sentence describing the verdict"}

Score is an integer 0..5. If the artifact lacks the evidence required by the
rubric, return pass:false with score:0 and say so in summary. Do not reward
effort, length, or tone.

<RUBRIC>
$(cat "$rub")
</RUBRIC>

<ARTIFACT path="$art">
$(cat "$art")
</ARTIFACT>
EOF
}

extract_json() {
  python3 - <<'PY' 2>/dev/null
import sys, json
s = sys.stdin.read()
i = s.find('{')
if i < 0:
    sys.exit(0)
depth = 0
for j in range(i, len(s)):
    c = s[j]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            try:
                json.loads(s[i:j+1]); print(s[i:j+1])
            except Exception:
                pass
            sys.exit(0)
PY
}

echo "# $gate  artifact=$art  rubric=$rub  n=$n  model=${model:-default}" > "$log"
pass_votes=0; total=0
for i in $(seq 1 "$n"); do
  echo "--- run $i ---" >> "$log"
  if [ -n "$model" ]; then
    out="$(claude -p --model "$model" "$(prompt)" 2>>"$log" || true)"
  else
    out="$(claude -p "$(prompt)" 2>>"$log" || true)"
  fi
  echo "$out" >> "$log"
  json="$(printf '%s' "$out" | extract_json || true)"
  if [ -z "$json" ]; then
    echo "[no JSON returned for run $i]" >> "$log"; continue
  fi
  p="$(printf '%s' "$json" | jq -r '.pass // false' 2>/dev/null)"
  total=$((total+1))
  [ "$p" = "true" ] && pass_votes=$((pass_votes+1))
done

verdict="FAIL"; [ "$total" -gt 0 ] && [ "$pass_votes" -gt $((total/2)) ] && verdict="PASS"
echo "$gate: $verdict ($pass_votes/$total runs passed)  audit=$log"
[ "$verdict" = "PASS" ]

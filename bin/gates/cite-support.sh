#!/usr/bin/env bash
# cite-support.sh: LLM-judge that every cited passage actually supports the
# claim near it. Cornerstone for any factual-output goal.
#
# Approach: pass the WHOLE artifact (with cite markers and an inline bibliography
# section) to the LLM via llm-judge.sh with a citation-support rubric. The judge
# is asked to find any claim whose cited source does not support it; pass iff
# none. Source fetching is the LLM's responsibility (via its tools). Fast,
# pragmatic; for source-fetching-strict checks, build a domain overlay.
#
# Usage: bin/gates/cite-support.sh <artifact> [--n K]

set -euo pipefail
art="${1:?usage: cite-support.sh <artifact> [--n K]}"
shift || true
[ -f "$art" ] || { echo "no artifact: $art" >&2; exit 2; }

dir="$(dirname "${BASH_SOURCE[0]}")"
rubric="$(mktemp --suffix=.md)"
trap 'rm -f "$rubric"' EXIT
cat > "$rubric" <<'EOF'
# Citation-support rubric

Read the artifact. For every load-bearing factual claim, identify the cited
source nearest to it (a footnote marker like [^N] or [KEY] or a URL). Judge
whether that source actually supports the claim as written.

PASS criteria (all must hold):
- Every load-bearing claim has a cite (no UNSUPPORTED claims).
- Every claim's cited source supports the claim (no DRIFTED paraphrases, no
  fabricated quotes or attributions).
- Numbers, dates, and named entities match the source.

FAIL otherwise. Score 0..5 based on how many claims have unsupported cites:
5 = none; 4 = one minor drift; 3 = two; 2 = three; 1 = many; 0 = systemic.

Return pass:true only at score >= 4.
EOF

exec "$dir/llm-judge.sh" "$art" "$rubric" --gate cite-support --n "${1:-1}" "$@"

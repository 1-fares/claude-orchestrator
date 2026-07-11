#!/usr/bin/env bash
# diff-summary.sh: compact change summary for a reviewer/integrator, so they can
# grasp a change without reading the whole diff. Prints the file/LOC stat and a
# heuristic list of added/removed public declarations (the API surface). The API
# section is pattern-based across common languages; skim the real diff for
# anything security- or contract-sensitive.
#
#   bin/tools/diff-summary.sh [GIT-RANGE]
#
# Default range: uncommitted work vs HEAD if the tree is dirty, else HEAD~1..HEAD.
# Examples: `diff-summary.sh main...HEAD`, `diff-summary.sh unit/parser`.
set -uo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "diff-summary: not a git repo" >&2; exit 2; }

range="${1:-}"
if [ -z "$range" ]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then range="HEAD"; else range="HEAD~1..HEAD"; fi
fi

echo "# diff-summary: $range"
stat="$(git diff --shortstat "$range" 2>/dev/null)"
echo "${stat:-  (no changes)}"

echo
echo "## files (+added -removed)"
git diff --numstat "$range" 2>/dev/null | awk '{printf "  +%-6s -%-6s %s\n", $1, $2, $3}'

echo
echo "## API surface changes (heuristic: added/removed declarations)"
pat='^[+-][[:space:]]*(export |public |private |protected |func |fn |pub fn |pub struct |def |async def |class |interface |type |struct |trait |enum |module\.exports|const [A-Z])'
out="$(git diff "$range" 2>/dev/null | grep -E "$pat" | grep -vE '^[+-]{3} ' | cut -c1-110)"
if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/  /'; else echo "  (none detected)"; fi

echo
echo "note: API section is heuristic; read the real diff for contract/security-sensitive changes."

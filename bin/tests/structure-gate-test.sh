#!/usr/bin/env bash
# structure-gate-test.sh: regression test for the g1 defect in bin/gates/structure.sh.
#
# The defect: the per-section range check built its heading->body map keying each
# section by the wrong regex group -- m.group(1), the leading '#' hashes -- instead
# of m.group(2), the heading text. Every section key was therefore a run of '#',
# so a rule like `sections: {Introduction: [100, 600]}` never matched a real
# heading and per-section min/max words were silently never enforced (the section
# read as "not found" regardless of content).
#
# Asserted here with a two-section fixture:
#   - a section within its [min,max] passes;
#   - a section under its min fails, named by heading text;
#   - a section over its max fails, named by heading text;
#   - a real heading is NOT reported "not found" (the direct group-index regression);
#   - a section's body stops at the next same-or-shallower heading (a deeper
#     subsection is counted inside the parent, a sibling is not).
#
# Fixtures are written under mktemp; nothing outside is touched.
#
# Usage: bin/tests/structure-gate-test.sh
# Exit:  0 = all assertions pass (or skipped for missing PyYAML), 1 = a failure.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
gate="$repo/bin/gates/structure.sh"
[ -f "$gate" ] || { echo "missing structure.sh at $gate" >&2; exit 2; }

# structure.sh needs PyYAML; without it the gate exits 2 and there is nothing to
# assert. Skip cleanly rather than reporting a false failure.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "structure-gate-test: PyYAML not available; skipping (install pyyaml to run)"
  exit 0
fi

pass=0; fail=0
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# run_gate <artifact> <rules>: combined out; exit in $?
run_gate() { local rc out; out="$(bash "$gate" "$1" "$2" 2>&1)"; rc=$?
  printf '%s' "$out"; return $rc; }

words() { local n="$1" out="" i=0; while [ "$i" -lt "$n" ]; do out="$out w$i"; i=$((i+1)); done
  printf '%s' "${out# }"; }

echo "structure.sh per-section ranges (g1)"

# ---------------------------------------------------------------------------
# 1. Both sections within range -> OK. Proves the sections are found by heading
#    text at all (pre-fix they were keyed by '#' and read as "not found").
# ---------------------------------------------------------------------------
art="$tmproot/ok.md"; rules="$tmproot/ok.yml"
{ printf '# Alpha\n\n%s\n\n# Beta\n\n%s\n' "$(words 5)" "$(words 8)"; } > "$art"
printf 'sections:\n  Alpha: [3, 10]\n  Beta: [5, 20]\n' > "$rules"
out="$(run_gate "$art" "$rules")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "both sections within range pass"
else bad "both sections within range pass" "exit $rc: $(printf '%s' "$out" | tr '\n' '|')"; fi
case "$out" in *"not found"*) bad "a real heading is not reported 'not found'" "output: $out" ;;
  *) ok "a real heading is not reported 'not found'" ;; esac

# ---------------------------------------------------------------------------
# 2. First section UNDER its min -> FAIL, named by heading text.
# ---------------------------------------------------------------------------
art="$tmproot/under.md"; rules="$tmproot/under.yml"
{ printf '# Alpha\n\n%s\n\n# Beta\n\n%s\n' "$(words 2)" "$(words 8)"; } > "$art"
printf 'sections:\n  Alpha: [3, 10]\n  Beta: [5, 20]\n' > "$rules"
out="$(run_gate "$art" "$rules")"; rc=$?
if [ "$rc" -eq 1 ]; then ok "section under min fails"
else bad "section under min fails" "exit $rc: $(printf '%s' "$out" | tr '\n' '|')"; fi
case "$out" in *"section 'Alpha'"*) ok "under-min failure names 'Alpha'" ;;
  *) bad "under-min failure names 'Alpha'" "output: $out" ;; esac

# ---------------------------------------------------------------------------
# 3. Second section OVER its max -> FAIL, named by heading text.
# ---------------------------------------------------------------------------
art="$tmproot/over.md"; rules="$tmproot/over.yml"
{ printf '# Alpha\n\n%s\n\n# Beta\n\n%s\n' "$(words 5)" "$(words 25)"; } > "$art"
printf 'sections:\n  Alpha: [3, 10]\n  Beta: [5, 20]\n' > "$rules"
out="$(run_gate "$art" "$rules")"; rc=$?
if [ "$rc" -eq 1 ]; then ok "section over max fails"
else bad "section over max fails" "exit $rc: $(printf '%s' "$out" | tr '\n' '|')"; fi
case "$out" in *"section 'Beta'"*) ok "over-max failure names 'Beta'" ;;
  *) bad "over-max failure names 'Beta'" "output: $out" ;; esac

# ---------------------------------------------------------------------------
# 4. Section body stops at the next same-or-shallower heading. A deeper
#    subsection's words count toward the parent; a sibling section's do not.
#    Alpha body = 4 words + a '## Sub' subsection with 3 words = 7 words,
#    which is within [5, 10]; Beta's 50 words must not leak into Alpha.
# ---------------------------------------------------------------------------
art="$tmproot/nested.md"; rules="$tmproot/nested.yml"
{ printf '# Alpha\n\n%s\n\n## Sub\n\n%s\n\n# Beta\n\n%s\n' \
    "$(words 4)" "$(words 3)" "$(words 50)"; } > "$art"
printf 'sections:\n  Alpha: [5, 10]\n' > "$rules"
out="$(run_gate "$art" "$rules")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "parent-section body spans its subsection but not the sibling"
else bad "parent-section body spans its subsection but not the sibling" \
        "exit $rc: $(printf '%s' "$out" | tr '\n' '|')"; fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

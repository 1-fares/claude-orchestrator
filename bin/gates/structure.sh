#!/usr/bin/env bash
# structure.sh: deterministic check that an artifact has the required headings
# and sits within word/section limits. Catches the dominant non-code failure
# mode: an agent silently drops a required section or returns a half-written
# deliverable.
#
# Usage:
#   bin/gates/structure.sh <artifact.md> <rules.yml>
#
# rules.yml shape (YAML):
#   required_headings: ["Introduction", "Conclusion"]   # exact heading text
#   min_words: 800
#   max_words: 5000
#   sections:                                            # optional per-heading
#     Introduction: [100, 600]                            #   [min, max] words
#     Conclusion:   [50, 400]

set -euo pipefail
art="${1:?usage: structure.sh <artifact> <rules.yml>}"
rules="${2:?usage: structure.sh <artifact> <rules.yml>}"
[ -f "$art" ] && [ -f "$rules" ] || { echo "missing artifact or rules" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 2; }

python3 - "$art" "$rules" <<'PY'
import sys, re
try:
    import yaml
except ImportError:
    print("structure: PyYAML missing (uv add pyyaml, or run via `uv run`)", file=sys.stderr); sys.exit(2)
art_path, rules_path = sys.argv[1], sys.argv[2]
text = open(art_path, encoding="utf-8", errors="replace").read()
rules = yaml.safe_load(open(rules_path, encoding="utf-8")) or {}
fails = []
# Total word count
words = re.findall(r"\b\w+\b", text)
total = len(words)
if "min_words" in rules and total < rules["min_words"]:
    fails.append(f"total words {total} < min {rules['min_words']}")
if "max_words" in rules and total > rules["max_words"]:
    fails.append(f"total words {total} > max {rules['max_words']}")
# Required headings (exact match anywhere as a heading)
heads = re.findall(r"^#{1,6}\s+(.+?)\s*$", text, re.M)
heads_set = {h.strip() for h in heads}
for h in rules.get("required_headings", []) or []:
    if h not in heads_set:
        fails.append(f"missing required heading: '{h}'")
# Per-section counts (split text on heading boundaries)
sec_rules = rules.get("sections") or {}
if sec_rules:
    # build map: heading -> body text until next heading of same-or-shallower level.
    # group(1) is the leading hashes (its length is the heading level); group(2)
    # is the heading text. The name must come from group(2): using group(1) here
    # made every section key a run of '#', so per-section ranges never matched.
    positions = [(m.start(), len(m.group(1)), m.group(2).strip(), m.end())
                 for m in re.finditer(r"^(#{1,6})\s+(.+?)\s*$", text, re.M)]
    bodies = {}
    for i, (pos, lvl, name, end) in enumerate(positions):
        nxt = len(text)
        for j in range(i+1, len(positions)):
            if positions[j][1] <= lvl:
                nxt = positions[j][0]; break
        bodies[name] = text[end:nxt]
    for name, rng in sec_rules.items():
        body = bodies.get(name)
        if body is None:
            fails.append(f"section '{name}': not found"); continue
        sw = len(re.findall(r"\b\w+\b", body))
        if sw < rng[0] or sw > rng[1]:
            fails.append(f"section '{name}': {sw} words outside [{rng[0]},{rng[1]}]")
if fails:
    print("structure: FAIL")
    for f in fails: print(f"  - {f}")
    sys.exit(1)
print(f"structure: OK  ({total} words, {len(heads)} headings)")
PY

#!/usr/bin/env bash
# dreamer-editscript-test.sh: unit tests for bin/lib/dream-lib.sh — the
# section indexer, the ops parser, and the mechanical applier that make the
# dreamer safe: unmentioned sections kept verbatim, fresh/undated sections
# protected, hallucinated headers rejected, removed bytes fully archived.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/lib/dream-lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { # name condition-exit-status
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

# Fixture ledger: prelude, an old settled chain (3 sections), an old dead
# section, an undated section, and a fresh section.
old1="## 2026-07-01 10:00 — investigate blob gap"
old2="## 2026-07-01 14:00 — blob gap: false positive found"
old3="## 2026-07-02 09:00 — blob gap RESOLVED: stale-key artifact"
dead="## 2026-07-03 08:00 — scratch notes (superseded)"
undated="## roster"
fresh="## $(date -u '+%Y-%m-%d') 08:00 — fresh work item"
cat > "$tmp/ledger.md" <<EOF
# Ledger
prelude line kept forever.

$old1
step one findings.

$old2
the earlier claim was wrong.

$old3
terminal state: nothing lost.

$dead
scratch content.

$undated
- role a
- role b

$fresh
do not touch me.
EOF

# --- sections index ------------------------------------------------------
dream_sections_index "$tmp/ledger.md" > "$tmp/idx"
check "index: 7 rows (prelude + 6 sections)" "$([ "$(wc -l < "$tmp/idx")" -eq 7 ]; echo $?)"
check "index: prelude row present" "$(grep -q '(prelude)' "$tmp/idx"; echo $?)"
# The undated '## roster' is a SIBLING of the dated '## ...' headers before
# it, not a sub-header: it must not borrow their date, or an open undated
# section could be archived. Only a deeper header inherits (below).
rosterdate="$(awk -F'\t' '$4 == "## roster" {print $3}' "$tmp/idx")"
check "index: undated sibling '## roster' after dated headers is protected (0)" "$([ "$rosterdate" = "0" ]; echo $?)"

# Inheritance is by nesting: a deeper header inherits from its nearest
# shallower open header; a sibling or shallower header closes the context.
cat > "$tmp/l3.md" <<'EOF'
## 2026-07-01 - dated parent
### 20:07 - time-only child
#### detail under the child
## unit: open-thing
status: in-progress
### note under the undated unit
## 2026-07-02 - next dated parent
### 09:00 - its child
EOF
d3() { dream_sections_index "$tmp/l3.md" | awk -F'\t' -v h="$1" '$4 == h {print $3}'; }
e1="$(date -u -d 2026-07-01 +%s)"; e2="$(date -u -d 2026-07-02 +%s)"
check "index: '### child' inherits its dated parent" "$([ "$(d3 '### 20:07 - time-only child')" = "$e1" ]; echo $?)"
check "index: '#### grandchild' inherits through the undated child" "$([ "$(d3 '#### detail under the child')" = "$e1" ]; echo $?)"
check "index: undated sibling '## unit:' after a dated '##' is protected (0)" "$([ "$(d3 '## unit: open-thing')" = "0" ]; echo $?)"
check "index: child of the undated sibling stays protected (0)" "$([ "$(d3 '### note under the undated unit')" = "0" ]; echo $?)"
check "index: a later dated parent and its child carry the new date" "$([ "$(d3 '## 2026-07-02 - next dated parent')" = "$e2" ] && [ "$(d3 '### 09:00 - its child')" = "$e2" ]; echo $?)"
# An undated header that follows a newer dated sibling inside the same dated parent
# takes the newer date: inheriting only the parent's older date would let it be
# archived as stale. An undated parent still lends nothing.
cat > "$tmp/l4.md" <<'EOF'
## 2026-09-01 - dated parent
### 2026-11-09 addendum
### addendum detail
## unit: undated parent
### 2026-11-09 dated child
### undated child after it
EOF
d4() { dream_sections_index "$tmp/l4.md" | awk -F'\t' -v h="$1" '$4 == h {print $3}'; }
e4="$(date -u -d 2026-11-09 +%s)"
check "index: undated '###' after a newer dated '###' takes the newer date" "$([ "$(d4 '### addendum detail')" = "$e4" ]; echo $?)"
check "index: under an undated parent an undated '###' stays protected (0)" "$([ "$(d4 '### undated child after it')" = "0" ]; echo $?)"
# An op on the undated sibling is rejected mechanically, not only by the prompt.
printf '<<<DREAM-OP ARCHIVE>>>\n<<<HEADER>>>## unit: open-thing\n<<<END-OP>>>\n' > "$tmp/ops3"
n3="$(dream_parse_ops "$tmp/ops3" "$tmp/opsdir3" 2>/dev/null)"
dream_apply_ops "$tmp/l3.md" "$tmp/opsdir3" "$n3" "$(date -u +%s)" "$tmp/new3" "$tmp/arch3" "$tmp/rej3"
check "apply: an op on the undated sibling is rejected (no derivable date)" "$([ $? -ne 0 ] && grep -q 'no derivable date' "$tmp/rej3"; echo $?)"
freshdate="$(awk -F'\t' -v h="$fresh" '$4 == h {print $3}' "$tmp/idx")"
check "index: fresh section dated today" "$([ "$freshdate" -gt $(( $(date -u +%s) - 86400 )) ]; echo $?)"

# A leading undated section (before any dated header) must be epoch 0.
printf '## undated first\nx\n## 2026-07-01 y\nz\n' > "$tmp/l2.md"
d0="$(dream_sections_index "$tmp/l2.md" | awk -F'\t' '$4 == "## undated first" {print $3}')"
check "index: undated-before-any-date is protected (0)" "$([ "$d0" = "0" ]; echo $?)"

# --- ops parse -----------------------------------------------------------
cat > "$tmp/ops" <<EOF
model chatter to ignore
<<<DREAM-OP COLLAPSE>>>
<<<HEADER>>>$old1
<<<HEADER>>>$old2
<<<HEADER>>>$old3
<<<REPLACEMENT>>>
## 2026-07-02 — blob gap RESOLVED (terminal)
stale-key artifact; nothing lost. (supersedes 3 archived entries)
<<<END-OP>>>
<<<DREAM-OP ARCHIVE>>>
<<<HEADER>>>$dead
<<<END-OP>>>
<<<DREAM-OP COLLAPSE>>>
<<<HEADER>>>## hallucinated header that does not exist
<<<REPLACEMENT>>>
## bogus
<<<END-OP>>>
<<<DREAM-OP ARCHIVE>>>
<<<HEADER>>>$fresh
<<<END-OP>>>
<<<DREAM-OP ARCHIVE>>>
<<<END-OP>>>
trailing chatter
EOF
nops="$(dream_parse_ops "$tmp/ops" "$tmp/opsdir" 2>/dev/null)"
check "parse: 4 structurally valid ops (empty op dropped)" "$([ "$nops" = "4" ]; echo $?)"

# --- apply ---------------------------------------------------------------
cutoff="$(( $(date -u +%s) - 48*3600 ))"
dream_apply_ops "$tmp/ledger.md" "$tmp/opsdir" "$nops" "$cutoff" \
  "$tmp/new" "$tmp/arch" "$tmp/rej"
check "apply: at least one op applied" "$?"

check "apply: collapsed replacement present" "$(grep -q 'blob gap RESOLVED (terminal)' "$tmp/new"; echo $?)"
check "apply: chain sections removed from new" "$(! grep -qF "$old1" "$tmp/new"; echo $?)"
check "apply: dead section removed from new" "$(! grep -qF "$dead" "$tmp/new"; echo $?)"
check "apply: prelude kept verbatim" "$(grep -q 'prelude line kept forever' "$tmp/new"; echo $?)"
check "apply: unmentioned roster kept verbatim" "$(grep -qF "$undated" "$tmp/new"; echo $?)"
check "apply: fresh section kept (op rejected)" "$(grep -qF "$fresh" "$tmp/new"; echo $?)"
check "apply: fresh-op rejection recorded" "$(grep -q 'fresh window' "$tmp/rej"; echo $?)"
check "apply: hallucinated-header op rejected" "$(grep -q 'not unique-or-found' "$tmp/rej"; echo $?)"
check "apply: provenance trailer added" "$(grep -q 'consolidated .* by dreamer' "$tmp/new"; echo $?)"

# Archive completeness: every removed section is in the archive verbatim.
for h in "$old1" "$old2" "$old3" "$dead"; do
  grep -qF "$h" "$tmp/arch" || { bad "archive holds: $h"; continue; }
  ok "archive holds: $h"
done
check "archive: body content of removed section present" "$(grep -q 'scratch content' "$tmp/arch"; echo $?)"

# No content invented or lost: new + archive together must cover every source
# line except nothing (replacement/trailer lines are the only additions).
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! grep -qF -- "$line" "$tmp/new" && ! grep -qF -- "$line" "$tmp/arch"; then
    bad "line lost: $line"
  fi
done < "$tmp/ledger.md"
ok "no source line lost (new + archive cover the file)"

# --- double-claim rejection ---------------------------------------------
cat > "$tmp/ops2" <<EOF
<<<DREAM-OP ARCHIVE>>>
<<<HEADER>>>$dead
<<<END-OP>>>
<<<DREAM-OP ARCHIVE>>>
<<<HEADER>>>$dead
<<<END-OP>>>
EOF
n2="$(dream_parse_ops "$tmp/ops2" "$tmp/opsdir2" 2>/dev/null)"
dream_apply_ops "$tmp/ledger.md" "$tmp/opsdir2" "$n2" "$cutoff" \
  "$tmp/new2" "$tmp/arch2" "$tmp/rej2" >/dev/null
check "apply: double-claimed section rejected once" "$(grep -q 'already claimed' "$tmp/rej2"; echo $?)"

# --- swap guard ----------------------------------------------------------
cp "$tmp/ledger.md" "$tmp/live.md"
ref="$(stat -c '%s %Y' "$tmp/live.md")"
cp "$tmp/new" "$tmp/candidate"
echo "concurrent append" >> "$tmp/live.md"
if dream_swap "$tmp/live.md" "$tmp/candidate" "$ref" 2>/dev/null; then
  bad "swap guard: accepted a changed file"
else
  ok "swap guard: refused changed file"
fi
check "swap guard: live file untouched" "$(grep -q 'concurrent append' "$tmp/live.md"; echo $?)"
cp "$tmp/new" "$tmp/candidate2"
ref2="$(stat -c '%s %Y' "$tmp/live.md")"
if dream_swap "$tmp/live.md" "$tmp/candidate2" "$ref2"; then
  ok "swap guard: clean swap succeeds"
else
  bad "swap guard: clean swap failed"
fi

# --- bank index maintenance (dream_append_index) -------------------------
bank="$tmp/bank"; mkdir -p "$bank"
cat > "$bank/MEMORY.md" <<'EOF'
# Memory bank

## feedback
- [existing-fb](feedback_existing.md) — an existing feedback entry.

## reference
- [existing-ref](existing-ref.md) — an existing reference entry.
EOF
cat > "$bank/feedback_existing.md" <<'EOF'
---
name: existing-fb
description: an existing feedback entry.
metadata:
  type: feedback
---
body
EOF
cat > "$bank/new-ref.md" <<'EOF'
---
name: new-ref
description: "a fresh reference fact, promoted tonight."
metadata:
  type: reference
---
body
EOF
cat > "$bank/proj-x.md" <<'EOF'
---
name: proj-x
description: a project status entry.
metadata:
  type: project
---
body
EOF

il="$(dream_index_line "$bank/new-ref.md")"
check "index-line: type prefix" "$(grep -q '^reference	' <<<"$il"; echo $?)"
check "index-line: markdown link + desc" "$(grep -qF -- '- [new-ref](new-ref.md) — a fresh reference fact' <<<"$il"; echo $?)"

dream_append_index "$bank/MEMORY.md" "$bank/new-ref.md" "$bank/proj-x.md" "$bank/feedback_existing.md" > "$tmp/mem.new"
check "append: new-ref indexed under reference section" "$(awk '/^## reference/{r=1;next} /^## /{r=0} r && /\(new-ref.md\)/{f=1} END{exit !f}' "$tmp/mem.new"; echo $?)"
check "append: existing reference line preserved" "$(grep -qF '(existing-ref.md)' "$tmp/mem.new"; echo $?)"
check "append: existing feedback line preserved" "$(grep -qF '(feedback_existing.md)' "$tmp/mem.new"; echo $?)"
check "append: already-indexed entry not duplicated" "$([ "$(grep -cF '(feedback_existing.md)' "$tmp/mem.new")" -eq 1 ]; echo $?)"
check "append: new project type gets its own section" "$(awk '/^## project/{p=1} p && /\(proj-x.md\)/{f=1} END{exit !f}' "$tmp/mem.new"; echo $?)"
check "append: no line dropped (line count grew by 2)" "$([ "$(grep -c '^- \[' "$tmp/mem.new")" -eq 4 ]; echo $?)"
# idempotency: re-running adds nothing
dream_append_index "$tmp/mem.new" "$bank/new-ref.md" "$bank/proj-x.md" > "$tmp/mem.new2"
check "append: idempotent on re-run" "$(diff -q "$tmp/mem.new" "$tmp/mem.new2" >/dev/null; echo $?)"

echo
echo "dreamer-editscript: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

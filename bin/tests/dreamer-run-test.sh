#!/usr/bin/env bash
# dreamer-run-test.sh: end-to-end tests for bin/dreamer.sh against a fixture
# run dir with a FAKE model binary: observer-history digestion (+ idempotent
# rerun), ledger consolidation via the full pipeline, report-only staging,
# quiescence gating, and the convergence floor (no model call when there is
# nothing eligible).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$repo/bin/tests/lib/isolate.sh"
# shellcheck disable=SC1091
. "$repo/bin/team-env.sh"
isolate_assert

trap 'rm -rf "$TEAM_DIR" "$stub_dir"' EXIT
mkdir -p "$TEAM_DIR/observer"
stub_dir="$(mktemp -d)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# --- fake model: emits the file named by FAKE_CLAUDE_OUTPUT, logs each call.
cat > "$stub_dir/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null   # drain stdin
echo "call $*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
[ -n "${FAKE_CLAUDE_STDERR:-}" ] && cat "$FAKE_CLAUDE_STDERR" >&2
# A write to the ledger while the model "thinks": the dreamer's swap guard must refuse.
[ -n "${FAKE_CLAUDE_TOUCH:-}" ] && echo "concurrent append" >> "$FAKE_CLAUDE_TOUCH"
cat "${FAKE_CLAUDE_OUTPUT:?}"
EOF
chmod +x "$stub_dir/claude"

# --- fake activity: per-role classification from a fixture dir.
cat > "$stub_dir/activity" <<'EOF'
#!/usr/bin/env bash
cat "${FAKE_ACT_DIR:?}/$1" 2>/dev/null || { echo idle; exit 0; }
EOF
chmod +x "$stub_dir/activity"

export FAKE_CLAUDE_LOG="$stub_dir/calls.log"
export FAKE_ACT_DIR="$stub_dir/act"
mkdir -p "$FAKE_ACT_DIR"

dreamer() {
  DREAMER_CLAUDE_BIN="$stub_dir/claude" \
  DREAMER_ACTIVITY_CMD="$stub_dir/activity" \
  DREAMER_SETTLE_SEC=0 \
  DREAMER_MIN_ELIGIBLE_LINES=10 \
  "$repo/bin/dreamer.sh" "$@" >/dev/null 2>&1
}

# --- fixture: observer history with 2 old days + 1 fresh entry ------------
today="$(date -u '+%Y-%m-%d')"
cat > "$TEAM_DIR/observer/history.md" <<EOF
=== 2026-07-01T08:00:00Z ===
HEADLINE: hold, all quiet
body a

=== 2026-07-01T08:15:00Z ===
HEADLINE: hold, all quiet
body b

=== 2026-07-02T09:00:00Z ===
HEADLINE: retire role x
body c

=== ${today}T05:00:00Z ===
HEADLINE: fresh entry stays
body d
EOF

# Fixture state.md: one old settled chain + one fresh section.
cat > "$TEAM_DIR/state.md" <<EOF
# state
## goal
build the thing

## 2026-07-01 10:00 — derive claim A
long derivation text line one
line two
line three of many words here
more filler to clear the eligible-lines floor
even more filler content lines
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler

## 2026-07-01 15:00 — claim A corrected
correction text
more correction filler lines
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler
filler filler filler filler

## ${today} 07:00 — fresh unit
fresh work, untouchable
EOF

# roster: one idle role
printf '123\t@1\tworker1\n' > "$TEAM_DIR/active"
echo idle > "$FAKE_ACT_DIR/worker1"

# Model output for the first full run: digests for both days + a collapse.
cat > "$stub_dir/out1" <<EOF
<<<DREAM-OP DIGEST-DAY date=2026-07-01>>>
quiet day, one repeated hold headline.
<<<END-OP>>>
<<<DREAM-OP DIGEST-DAY date=2026-07-02>>>
observer recommended retiring role x.
<<<END-OP>>>
<<<DREAM-OP COLLAPSE>>>
<<<HEADER>>>## 2026-07-01 10:00 — derive claim A
<<<HEADER>>>## 2026-07-01 15:00 — claim A corrected
<<<REPLACEMENT>>>
## 2026-07-01 — claim A terminal: corrected version stands
(supersedes 2 archived entries)
<<<END-OP>>>
EOF
export FAKE_CLAUDE_OUTPUT="$stub_dir/out1"

# ============ 1. quiescence gate =========================================
echo working > "$FAKE_ACT_DIR/worker1"
dreamer
check "busy roster: no report written" "$([ ! -f "$TEAM_DIR/dreams/latest-report.md" ]; echo $?)"
check "busy roster: history untouched" "$(grep -q 'body a' "$TEAM_DIR/observer/history.md"; echo $?)"
echo idle > "$FAKE_ACT_DIR/worker1"

# Every real `claude` start prints a known deny-rule note on stderr, and run_model appends stderr to
# dreams/dreamer.log. The fake prints a real error line AND the note on every call; checked after section 3.
printf '%s\n%s\n' 'API Error: 529 overloaded_error (dreamer stderr fixture)' \
  'Permission deny rule (.claude/settings.json): Bash(git push * :**) has a :* that is not at the end, so it is matched as a * wildcard (the : is literal), not as the trailing :* prefix syntax. It already matches as a * wildcard; moving :* to the end would make it a literal prefix and change which commands match.' > "$stub_dir/stderr"
export FAKE_CLAUDE_STDERR="$stub_dir/stderr"

# ============ 2. report-only run =========================================
dreamer --report-only
check "report-only: report exists" "$([ -f "$TEAM_DIR/dreams/latest-report.md" ]; echo $?)"
check "report-only: history.md unchanged" "$(grep -q 'body a' "$TEAM_DIR/observer/history.md"; echo $?)"
check "report-only: state.md unchanged" "$(grep -q 'long derivation text' "$TEAM_DIR/state.md"; echo $?)"
staged_dir="$(ls -1dt "$TEAM_DIR"/dreams/staged/* 2>/dev/null | head -1)"
check "report-only: staged history present" "$([ -n "$staged_dir" ] && [ -f "$staged_dir/observer-history.md" ]; echo $?)"

# ============ 3. apply run ===============================================
sleep 1   # ensure a distinct minute-stamp is not required; distinct mtimes help
dreamer
check "apply: digest has day 1" "$(grep -q '^## 2026-07-01' "$TEAM_DIR/observer/history-digest.md"; echo $?)"
check "apply: digest has day 2" "$(grep -q '^## 2026-07-02' "$TEAM_DIR/observer/history-digest.md"; echo $?)"
check "apply: history keeps fresh entry" "$(grep -q 'fresh entry stays' "$TEAM_DIR/observer/history.md"; echo $?)"
check "apply: history dropped old entries" "$(! grep -q 'body a' "$TEAM_DIR/observer/history.md"; echo $?)"
arch="$(ls -1 "$TEAM_DIR"/dreams/archive/*/observer-history.*.md.gz 2>/dev/null | head -1)"
check "apply: raw old entries archived (gz)" "$([ -n "$arch" ] && { _pgq="$(zcat "$arch")" && grep -q 'body a' <<<"$_pgq"; }; echo $?)"
check "apply: state.md collapsed" "$(grep -q 'claim A terminal' "$TEAM_DIR/state.md"; echo $?)"
check "apply: state.md fresh section kept" "$(grep -q 'fresh unit' "$TEAM_DIR/state.md"; echo $?)"
check "apply: originals in state-archive.md" "$(grep -q 'long derivation text' "$TEAM_DIR/state-archive.md"; echo $?)"
check "apply: dream marker in state.md" "$(grep -q '^_last dream: ' "$TEAM_DIR/state.md"; echo $?)"

# stderr checks. The first is the positive precondition: "no note in the log" also passes on an empty log.
check "stderr: model calls were made"               "$([ -s "$FAKE_CLAUDE_LOG" ]; echo $?)"
check "stderr: real error line kept in dreamer.log" "$(grep -qF 'dreamer stderr fixture' "$TEAM_DIR/dreams/dreamer.log"; echo $?)"
check "stderr: known deny-rule note dropped"        "$(! grep -qF 'Permission deny rule (.claude/settings.json): Bash(git push * :**)' "$TEAM_DIR/dreams/dreamer.log"; echo $?)"
unset FAKE_CLAUDE_STDERR

# ============ 4. idempotent rerun ========================================
# Model now (correctly) has nothing; also verify no duplicate digest days if
# it misbehaves and re-emits day blocks.
cat > "$stub_dir/out2" <<'EOF'
<<<DREAM-NO-OPS>>>
EOF
export FAKE_CLAUDE_OUTPUT="$stub_dir/out2"
# state.md: only the dream marker line may differ (same stamp-format), so
# both sums are taken with the marker lines stripped.
before_digest="$(md5sum "$TEAM_DIR/observer/history-digest.md")"
before_state="$(grep -v '^_last dream: ' "$TEAM_DIR/state.md" | md5sum)"
dreamer
after_digest="$(md5sum "$TEAM_DIR/observer/history-digest.md")"
after_state="$(grep -v '^_last dream: ' "$TEAM_DIR/state.md" | md5sum)"
check "rerun: digest unchanged" "$([ "$before_digest" = "$after_digest" ]; echo $?)"
check "rerun: state.md unchanged apart from marker" "$([ "$before_state" = "$after_state" ]; echo $?)"

# ============ 5. convergence floor =======================================
# state.md is now small: the eligible-lines floor must prevent a model call.
: > "$FAKE_CLAUDE_LOG"
dreamer --artifact state
check "floor: no model call on converged ledger" "$([ ! -s "$FAKE_CLAUDE_LOG" ]; echo $?)"

# ============ 6. ledger pass outcomes, as the report states them =========
# mkstate: a fresh state.md with one old chain above the eligible-lines floor.
mkstate() {
  {
    echo "# state"
    echo "## 2026-07-03 10:00 - derive claim B"
    for i in 1 2 3 4 5 6 7 8; do echo "claim B derivation line $i"; done
    echo
    echo "## 2026-07-03 15:00 - claim B corrected"
    for i in 1 2 3 4 5 6 7 8; do echo "claim B correction line $i"; done
  } > "$TEAM_DIR/state.md"
}
cat > "$stub_dir/out-b" <<'EOF'
<<<DREAM-OP COLLAPSE>>>
<<<HEADER>>>## 2026-07-03 10:00 - derive claim B
<<<HEADER>>>## 2026-07-03 15:00 - claim B corrected
<<<REPLACEMENT>>>
## 2026-07-03 - claim B terminal
(supersedes 2 archived entries)
<<<END-OP>>>
EOF
rep="$TEAM_DIR/dreams/latest-report.md"

# 6a. no protocol marker at all vs every op malformed: two different PROBLEM lines.
mkstate
printf 'I looked at the ledger and it seems fine.\n' > "$stub_dir/out-prose"
FAKE_CLAUDE_OUTPUT="$stub_dir/out-prose" dreamer --artifact state
check "no-marker: reported as a PROBLEM, not as nothing to do" "$(grep -q 'state: PROBLEM: model output has no COLLAPSE/ARCHIVE op marker' "$rep"; echo $?)"
check "no-marker: the start of the output is quoted" "$(grep -q 'I looked at the ledger' "$rep"; echo $?)"
printf '<<<DREAM-OP COLLAPSE>>>\n<<<REPLACEMENT>>>\nx\n<<<END-OP>>>\n<<<DREAM-OP ARCHIVE>>>\n<<<END-OP>>>\n' > "$stub_dir/out-bad"
FAKE_CLAUDE_OUTPUT="$stub_dir/out-bad" dreamer --artifact state
check "malformed: reported with the op count" "$(grep -q 'state: PROBLEM: 2 op block(s) emitted, all malformed and dropped' "$rep"; echo $?)"
check "malformed: state.md untouched" "$(grep -q 'claim B derivation line 1' "$TEAM_DIR/state.md"; echo $?)"

# 6b. "applied" only after the swap: a write during the model call makes the swap refuse.
mkstate
FAKE_CLAUDE_TOUCH="$TEAM_DIR/state.md" FAKE_CLAUDE_OUTPUT="$stub_dir/out-b" dreamer --artifact state
check "swap refused: reported" "$(grep -q 'SWAP REFUSED' "$rep"; echo $?)"
check "swap refused: no 'applied' line" "$(! grep -q 'applied: ops=' "$rep"; echo $?)"
check "swap refused: the candidate line does not claim it applied" "$(grep -q 'state: ops=1 parsed into a candidate' "$rep"; echo $?)"
check "swap refused: state.md keeps the chain" "$(grep -q 'claim B derivation line 1' "$TEAM_DIR/state.md"; echo $?)"

# 6c. the archive append is verified before the swap: an unwritable archive target aborts the pass.
mkstate
mv "$TEAM_DIR/state-archive.md" "$stub_dir/state-archive.saved"
mkdir "$TEAM_DIR/state-archive.md"   # a directory: the append fails whatever the user's privileges
FAKE_CLAUDE_OUTPUT="$stub_dir/out-b" dreamer --artifact state
check "archive failure: reported" "$(grep -q 'ARCHIVE WRITE/VERIFY FAILED (state-archive.md); pass aborted' "$rep"; echo $?)"
check "archive failure: no 'applied' line" "$(! grep -q 'applied: ops=' "$rep"; echo $?)"
check "archive failure: state.md keeps the chain" "$(grep -q 'claim B derivation line 1' "$TEAM_DIR/state.md" && ! grep -q 'claim B terminal' "$TEAM_DIR/state.md"; echo $?)"
rmdir "$TEAM_DIR/state-archive.md"; mv "$stub_dir/state-archive.saved" "$TEAM_DIR/state-archive.md"

# 6d. the normal path: archived, verified, swapped, then "applied".
mkstate
FAKE_CLAUDE_OUTPUT="$stub_dir/out-b" dreamer --artifact state
check "apply: 'applied' logged after the swap" "$(grep -q 'applied: ops=1, .* swapped; originals in state-archive.md' "$rep"; echo $?)"
check "apply: state.md collapsed" "$(grep -q 'claim B terminal' "$TEAM_DIR/state.md" && ! grep -q 'claim B derivation line 1' "$TEAM_DIR/state.md"; echo $?)"
check "apply: the archive ends with the removed sections" "$([ "$(tail -n 1 "$TEAM_DIR/state-archive.md")" = 'claim B correction line 8' ]; echo $?)"

echo
echo "dreamer-run: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

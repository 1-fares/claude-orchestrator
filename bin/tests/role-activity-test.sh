#!/usr/bin/env bash
# role-activity-test.sh: fixture-driven tests for bin/role-activity.sh, exercising
# the spinner/idle classifier without a live tmux pane (ROLE_ACTIVITY_CAPTURE).
#
# Regression coverage for the two false-classification bugs (2026-05-30):
#   - false IDLE: an active spinner whose token readout uses a k/m suffix
#     ("↓ 59.7k tokens") or whose gerund is not "Working"/"Thinking" was read as
#     idle, because the old token regex was integer-only and the verb list was a
#     hardcoded subset.
#   - false WORKING: the PAST-tense idle completion summary
#     ("Brewed for 40s · 1 monitor still running") matched the old busy regex,
#     which listed "Brewed for"/"Cooked for".

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/../role-activity.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
check() { # name expected fixture-text
  local name="$1" expected="$2" text="$3" got
  printf '%s' "$text" > "$tmp/cap"
  got="$(ROLE_ACTIVITY_CAPTURE="$tmp/cap" "$SCRIPT" tester1 2>/dev/null)"
  if [ "$got" = "$expected" ]; then
    pass=$((pass+1)); printf '  ok   %-42s -> %s\n' "$name" "$got"
  else
    fail=$((fail+1)); printf '  FAIL %-42s -> got "%s", want "%s"\n' "$name" "$got" "$expected"
  fi
}

INPUT_BOX=$'────────\n❯ \n────────\n  -- INSERT -- ⏵⏵ bypass permissions on · 1 monitor'

# --- active spinners (must be `working`) ---
check "active Working + k-suffix tokens" working \
  "● Running 1 shell command…
✽ Working… (1m 23s · ↓ 4.3k tokens)
$INPUT_BOX"

check "active Thinking + 59.7k tokens (false-idle repro)" working \
  "  ⎿  ls /home/user/project/...
✽ Thinking… (13m 59s · ↓ 59.7k tokens · thought for 1s)
$INPUT_BOX"

check "active whimsical verb (verb-agnostic)" working \
  "✶ Percolating… (5s · ↓ 2.1k tokens)
$INPUT_BOX"

check "active esc-to-interrupt during tool" working \
  "● Bash(git status)
  ⎿  Running… (esc to interrupt)
$INPUT_BOX"

# --- idle completion summaries (must be `idle`) ---
check "idle Brewed-for completion (false-working repro)" idle \
  "  [2026-05-30 18:06 Etc/UTC]
✻ Brewed for 40s · 1 monitor still running
                            new task? /clear to save 386.1k tokens
$INPUT_BOX"

check "idle Worked-for completion" idle \
  "✻ Worked for 8m 11s · 1 monitor still running
                            new task? /clear to save 138.9k tokens
$INPUT_BOX"

check "idle Cooked-for completion" idle \
  "✻ Cooked for 12s · 1 monitor still running
                            new task? /clear to save 90k tokens
$INPUT_BOX"

check "idle bare prompt" idle "$INPUT_BOX"

# --- stale scrollback must not leak past the spinner zone (bottom-anchored) ---
check "stale spinner high in scrollback, idle now" idle \
  "✽ Working… (2s · ↓ 5.0k tokens)
line03
line04
line05
line06
line07
line08
line09
line10
line11
line12
line13
✻ Worked for 1m · 1 monitor still running
                            new task? /clear to save 50k tokens
$INPUT_BOX"

# --- delegation ---
check "delegating with count" delegating:2 \
  "● Running 2 background tasks
$INPUT_BOX"

check "delegating bare Task( no spinner" delegating \
  "● Agent(analyze X)
  ⎿  Task(analyze X)
$INPUT_BOX"

echo
echo "role-activity: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Unit test for bin/lib/watchdog-detect.sh — the pane detectors that the
# api-watchdog stuck-detection rests on. No tmux, no daemon; pure functions on
# sample pane captures. Run: bin/tests/watchdog-detect-test.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/lib/watchdog-detect.sh"

# Mirror the daemon's pattern_regex build so _classify_text behaves identically.
pattern_regex="$(grep -vE '^[[:space:]]*(#|$)' "$repo/bin/api-watchdog.patterns" | paste -sd'|' -)"

fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
eq()   { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected '$3', got '$2'"; }
ne()   { [ "$2" != "$3" ] && ok "$1" || bad "$1: expected != '$3', got '$2'"; }

# --- samples ----------------------------------------------------------------
# A wedged role: a hung tool call, spinner up, only the elapsed timer ticking.
wedged_a() { cat <<'EOF'
● Found it: reqid=8675 POST /chat [202]. Let me get the request payload.
  [2026-05-29 22:45 Europe/Zurich]
  Calling chrome-devtools…
· Working… (39m 12s · ↓ 34.4k tokens · esc to interrupt)
────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on · 1 monitor
EOF
}
# Same wedge, two minutes later: ONLY the spinner timer changed.
wedged_b() { cat <<'EOF'
● Found it: reqid=8675 POST /chat [202]. Let me get the request payload.
  [2026-05-29 22:45 Europe/Zurich]
  Calling chrome-devtools…
· Working… (41m 03s · ↓ 34.4k tokens · esc to interrupt)
────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on · 1 monitor
EOF
}
# Real progress: a new output line appeared (and tokens climbed).
progress() { cat <<'EOF'
● Found it: reqid=8675 POST /chat [202]. Let me get the request payload.
  [2026-05-29 22:45 Europe/Zurich]
● Payload confirmed: addressed_to=role:implementer1. Taking screenshot now.
· Working… (41m 03s · ↓ 35.1k tokens · esc to interrupt)
────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on · 1 monitor
EOF
}
# Idle at the prompt, turn finished, no error.
idle() { cat <<'EOF'
● Done. Reported done: to orchestrator.
  [2026-05-29 22:50 Europe/Zurich]
────────────────────────────────────────────────────────────────────────────
❯ Try "edit <filepath>"
────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on
EOF
}
# API-stalled: idle at the prompt with a retryable error in recent output.
stalled() { cat <<'EOF'
● Starting the verification run.
  API Error: Connection error. (Retrying may help.)
────────────────────────────────────────────────────────────────────────────
❯ Try "edit <filepath>"
────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on
EOF
}
# Idle at the prompt, but with the persistent "· N monitor" chrome in the
# status bar — the real shape of an idle role (the inter-session monitor is
# always running). The monitor count must NOT be read as a busy marker, or a
# role that legitimately holds at its prompt past the threshold is falsely
# flagged stuck. Regression for that false-stuck.
idle_monitor() { cat <<'EOF'
● Standing by — holding for infra to resolve access.
  [2026-05-30 10:18 Etc/UTC]
────────────────────────────────────────────────────────────────────────────
❯ Standing by — holding for infra to resolve access.
────────────────────────────────────────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on · 1 monitor
EOF
}
# Blocked on an interactive selection menu (AskUserQuestion / plan / permission)
# awaiting a human decision. Not busy (no spinner), not a plain idle prompt:
# the run is BLOCKED until a human answers. Must classify awaiting-input so the
# watchdog escalates instead of reading it as a healthy idle role. This is the
# silent team-wide stall a real run hit (orchestrator parked on a menu 19h).
menu() { cat <<'EOF'
● The resumed ledger carries two workstreams. How should the team proceed?
❯ 1. Hold steady-state only
  2. Resume the parked workstream now
  3. Type something
────────────────────────────────────────────────────────────────────────────
  Enter to select · ↑/↓ to navigate · Esc to cancel
EOF
}
# Blocked on a yes/no confirmation prompt.
confirm() { cat <<'EOF'
● Edit src/templates/invoice.ts?
  Do you want to proceed?
❯ 1. Yes
  2. No, and tell me what to do differently
────────────────────────────────────────────────────────────────────────────
EOF
}
# Parked on the usage-limit dialog: the account ran out of usage and Claude
# Code replaced the prompt with a modal. No spinner, no API-error text, no
# 'Enter to select' footer, and the '❯' on the selected option satisfies the
# idle-prompt check — before the stalled-usage class this classified as
# healthy-idle "active" and a real usage outage silently parked most of a
# team (2026-07-10). Must classify stalled-usage (auto-recoverable).
usage_dialog() { cat <<'EOF'
● Drafting the next section now.
  You've reached your usage limit.
   ❯ 1. Stop and wait for limit to reset
     2. Add funds to continue with usage credits
     3. Switch to Team plan
   Enter to confirm · Esc to cancel
EOF
}
# A non-usage modal dialog with the 'Enter to confirm' footer: not
# auto-recoverable, so it must classify awaiting-input (page a human), not
# slip through as idle.
modal_confirm() { cat <<'EOF'
● Session settings
❯ 1. Keep current configuration
  2. Change model
  Enter to confirm · Esc to cancel
EOF
}

echo "fingerprint stability (the core stuck discriminator):"
fa="$(wedged_a | _fingerprint_text)"
fb="$(wedged_b | _fingerprint_text)"
fp="$(progress | _fingerprint_text)"
eq "wedge fingerprint stable across timer-only change" "$fa" "$fb"
ne "wedge fingerprint changes on real progress" "$fp" "$fa"

echo "is_busy:"
wedged_a | _is_busy_text && eq "wedged is busy" "busy" "busy" || bad "wedged should be busy"
idle     | _is_busy_text && bad "idle should NOT be busy" || ok "idle not busy"
stalled  | _is_busy_text && bad "stalled should NOT be busy" || ok "stalled not busy"
idle_monitor | _is_busy_text && bad "idle with '· 1 monitor' should NOT be busy" || ok "idle with monitor not busy"
menu     | _is_busy_text && bad "menu should NOT be busy" || ok "menu not busy"

echo "classify:"
eq "wedged classifies active (the blind spot api-stall can't see)" "$(wedged_a | _classify_text)" "active"
eq "idle classifies active"        "$(idle    | _classify_text)" "active"
eq "stalled classifies stalled-api" "$(stalled | _classify_text)" "stalled-api"

echo "awaiting-input (the silent team-wide stall this guard closes):"
menu    | _is_awaiting_input_text && ok "menu is awaiting-input" || bad "menu should be awaiting-input"
confirm | _is_awaiting_input_text && ok "confirm is awaiting-input" || bad "confirm should be awaiting-input"
idle    | _is_awaiting_input_text && bad "idle should NOT be awaiting-input" || ok "idle not awaiting-input"
wedged_a | _is_awaiting_input_text && bad "wedged should NOT be awaiting-input" || ok "wedged not awaiting-input"
eq "menu classifies awaiting-input"    "$(menu    | _classify_text)" "awaiting-input"
eq "confirm classifies awaiting-input" "$(confirm | _classify_text)" "awaiting-input"
eq "idle still classifies active (not awaiting)" "$(idle | _classify_text)" "active"
eq "idle_monitor classifies active (not stuck, not awaiting)" "$(idle_monitor | _classify_text)" "active"

echo "usage-stall (the silent usage-outage park this guard closes):"
eq "usage dialog classifies stalled-usage" "$(usage_dialog | _classify_text)" "stalled-usage"
usage_dialog | _is_usage_stall_text && ok "usage dialog is a usage stall" || bad "usage dialog should be a usage stall"
usage_dialog | _is_busy_text && bad "usage dialog should NOT be busy" || ok "usage dialog not busy"
usage_dialog | _has_modal_dialog_text && ok "usage dialog is a modal (Escape needed)" || bad "usage dialog should read as a modal"
eq "non-usage 'Enter to confirm' modal classifies awaiting-input" "$(modal_confirm | _classify_text)" "awaiting-input"
idle | _is_usage_stall_text && bad "idle should NOT be a usage stall" || ok "idle not a usage stall"
stalled | _is_usage_stall_text && bad "api-stalled should NOT be a usage stall" || ok "api-stalled not a usage stall"

# A long legitimate THINK: body static, but the token counter climbs. The
# daemon must read this as alive (not wedged) via the token readout, even
# though the fingerprint is static.
think_a() { cat <<'EOF'
● Analyzing the integrator node screenshot for the alert-hue check…
· Thinking… (8m 02s · ↓ 34.4k tokens · esc to interrupt)
────────────────────────────────────────────────────────────────────────────
❯
EOF
}
think_b() { cat <<'EOF'
● Analyzing the integrator node screenshot for the alert-hue check…
· Thinking… (12m 40s · ↓ 46.0k tokens · esc to interrupt)
────────────────────────────────────────────────────────────────────────────
❯
EOF
}
echo "token-readout liveness (keeps a long think from reading as a wedge):"
eq "long think fingerprint is static (body unchanged)" "$(think_a | _fingerprint_text)" "$(think_b | _fingerprint_text)"
ne "but token readout advances => alive" "$(think_a | _token_readout)" "$(think_b | _token_readout)"
eq "wedge token readout is frozen => not alive" "$(wedged_a | _token_readout)" "$(wedged_b | _token_readout)"

echo
if [ "$fail" = 0 ]; then echo "PASS: all watchdog-detect assertions"; exit 0
else echo "FAIL: see above"; exit 1; fi

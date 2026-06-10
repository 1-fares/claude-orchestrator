#!/usr/bin/env bash
# Unit test for parse_context_pct in bin/lib/compaction-detect.sh — the /context
# total-% parser the proactive compaction watchdog rests on. Pure; no tmux.
# Run: bin/tests/compaction-probe-test.sh
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$repo/bin/lib/compaction-detect.sh"

fail=0
eq() { [ "$2" = "$3" ] && printf '  ok   %s (%s)\n' "$1" "$2" || { printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$3" "$2"; fail=1; }; }

# 2.1.x near-full: the authoritative total is the "NN% context used" footer (no
# parens); a warning block appears; the only parenthesised numbers are decimal
# per-category lines. This exact shape silently blinded the old parser.
new_full() { cat <<'EOF'
     ⛁ Skills: 2.7k tokens (0.3%)
                                               ⛁ Messages: 1.2m tokens (116.8%)
     /context all to expand
      ⚠ Context is 96% full
        Autocompact will trigger soon, which discards older messages. Use
                                             98% context used · /model opus[1m]
EOF
}
# 2.1.x mid-range: footer present, no warning.
new_mid() { cat <<'EOF'
     ⛁ System tools: 13.2k tokens (1.3%)
     ⛁ Memory files: 12.7k tokens (1.3%)
     /context all to expand
                                              8% context used · /model opus[1m]
EOF
}
# Older format: parenthesised total on the "/1m tokens (NN%)" line, no footer.
old_fmt() { cat <<'EOF'
     931.6k/1m tokens (93%)
     ⛁ System prompt: 2.5k tokens (0.2%)
     ⛁ Skills: 2.6k tokens (0.3%)
EOF
}
# Near-full warning but no footer captured in the window.
warn_only() { cat <<'EOF'
      ⚠ Context is 96% full
        Autocompact will trigger soon, which discards older messages.
EOF
}
# No total signal at all (only decimal category lines) -> empty, so the daemon
# logs "could not read context %" rather than acting on a wrong number.
decimals_only() { cat <<'EOF'
     ⛁ System tools: 13.2k tokens (1.3%)
     ⛁ Memory files: 12.7k tokens (1.3%)
     ⛁ MCP tools: 101 tokens (0.0%)
EOF
}
# Claude Code 2.1.170: /context dropped the "NN% context used" footer AND the
# "/<size> tokens (NN%)" total line. The only whole-context signal is the
# "Free space: NNNk (NN.N%)" row; used% = 100 - free% (free floored). Sanitised
# generic pane text; the percentage-line shapes are the real 2.1.170 ones.
v2170_mid() { cat <<'EOF'
     ⛶ ⛶ ⛶   ⛁ System prompt: 3.1k tokens (0.3%)
     ⛶ ⛶ ⛶   ⛁ System tools: 15.4k tokens (1.5%)
     ⛶ ⛶ ⛶   ⛁ Memory files: 8.6k tokens (0.9%)
     ⛶ ⛶ ⛶   ⛁ Skills: 2.7k tokens (0.3%)
     ⛶ ⛶ ⛶   ⛁ Messages: 47.4k tokens (4.7%)
                  ⛶ Free space: 923.3k (92.3%)
     /context all to expand
EOF
}
v2170_high() { cat <<'EOF'
     ⛁ Messages: 880.0k tokens (88.0%)
                  ⛶ Free space: 41.0k (4.1%)
     /context all to expand
EOF
}

echo "parse_context_pct:"
eq "new near-full footer wins (98% context used)" "$(new_full      | parse_context_pct)" "98"
eq "new mid-range footer (8% context used)"       "$(new_mid       | parse_context_pct)" "8"
eq "older parenthesised total line (93%)"         "$(old_fmt       | parse_context_pct)" "93"
eq "warning-only falls back to the warn %"        "$(warn_only     | parse_context_pct)" "96"
eq "decimal category lines alone -> empty"        "$(decimals_only | parse_context_pct)" ""
eq "2.1.170 free-space mid -> 100-92 = 8"         "$(v2170_mid     | parse_context_pct)" "8"
eq "2.1.170 free-space high -> 100-4 = 96"        "$(v2170_high    | parse_context_pct)" "96"

# _ceiling_state — the busy-agnostic guard that catches a near-full/wedged
# orchestrator from the live pane (no /context probe). These strings render even
# while the session is busy, which the idle-gated probe never sees.
healthy_busy() { printf '● Calling ms365…\n· Working… (12s · esc to interrupt)\n❯ \n'; }
near_full()    { printf '%s\n' '⚠ Context is 96% full' 'Autocompact will trigger soon, which discards older messages.' '98% context used · /model opus[1m]'; }
autocompact()  { printf '%s\n' 'Autocompact will trigger soon'; }
hard_limit()   { printf '%s\n' '⎿  Context limit reached · /compact or /clear to continue'; }
compact_fail() { printf '%s\n' '⎿  Error: Compaction failed · conversation could not be reduced below the context limit'; }

echo "_ceiling_state (busy-agnostic ceiling guard):"
eq "healthy/busy pane -> empty"            "$(healthy_busy | _ceiling_state)" ""
eq "near-full warning -> warn"             "$(near_full    | _ceiling_state)" "warn"
eq "autocompact-soon -> warn"              "$(autocompact  | _ceiling_state)" "warn"
eq "context limit reached -> limit"        "$(hard_limit   | _ceiling_state)" "limit"
eq "compaction failed -> compact-failed"   "$(compact_fail | _ceiling_state)" "compact-failed"
# worst-first priority: a pane showing BOTH limit and failed reads as compact-failed
eq "limit+failed together -> compact-failed (worst first)" "$( { hard_limit; compact_fail; } | _ceiling_state)" "compact-failed"

echo
if [ "$fail" = 0 ]; then echo "PASS: all compaction-probe assertions"; exit 0
else echo "FAIL: see above"; exit 1; fi

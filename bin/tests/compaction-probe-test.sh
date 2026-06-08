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

echo "parse_context_pct:"
eq "new near-full footer wins (98% context used)" "$(new_full      | parse_context_pct)" "98"
eq "new mid-range footer (8% context used)"       "$(new_mid       | parse_context_pct)" "8"
eq "older parenthesised total line (93%)"         "$(old_fmt       | parse_context_pct)" "93"
eq "warning-only falls back to the warn %"        "$(warn_only     | parse_context_pct)" "96"
eq "decimal category lines alone -> empty"        "$(decimals_only | parse_context_pct)" ""

echo
if [ "$fail" = 0 ]; then echo "PASS: all compaction-probe assertions"; exit 0
else echo "FAIL: see above"; exit 1; fi

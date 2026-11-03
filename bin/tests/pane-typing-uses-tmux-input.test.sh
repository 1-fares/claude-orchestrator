#!/usr/bin/env bash
# pane-typing-uses-tmux-input.test.sh: a script that types literal text into a pane (send-keys -l) must load
# bin/lib/tmux-input.sh, directly or through bin/lib/tmux-submit.sh (which sources it), so the typing goes through
# ti_send (force INSERT, confirm, submit). A script that only sources bin/team-env.sh types through tmux_submit and has
# no send-keys -l of its own. In vim NORMAL a blind send-keys -l is read as commands: "try again" arrived as "gain".
# The blind recipes left in those files run only where ti_send finds no input box in a pane that is a shell.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0; n=0
EXEMPT=" bin/lib/tmux-input.sh "
while IFS= read -r f; do
  rel="${f#"$repo"/}"
  case "$EXEMPT" in *" $rel "*) continue ;; esac
  grep -qE 'send-keys[^#]* -l ' "$f" || continue
  n=$((n+1))
  if grep -qE '^[[:space:]]*\. "(\$repo/bin/lib|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\))/tmux-(input|submit)\.sh"' "$f"; then
    echo "  ok   $rel types through tmux-input.sh"
  else
    fail=1; echo "  FAIL $rel has send-keys -l but does not load bin/lib/tmux-input.sh"
  fi
done < <(find "$repo/bin" -path "$repo/bin/tests" -prune -o -type f \( -name '*.sh' -o ! -name '*.*' \) -print | sort)
[ "$n" -gt 0 ] || { echo "pane-typing-uses-tmux-input.test: FAIL (no send-keys -l found at all; the scan is broken)"; exit 1; }
[ "$fail" = 0 ] && echo "pane-typing-uses-tmux-input.test: PASS ($n)" || { echo "pane-typing-uses-tmux-input.test: FAIL"; exit 1; }

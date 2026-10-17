#!/usr/bin/env bash
# PreToolUse(Bash) gate, operator ruling, 2026-10-17: no rm, unlink, xargs rm or find -delete with a
# wildcard or a variable in the path, in any Bash tool call (roles and sub-agents; wired at user level).
# 2026-10-17 06:50:45Z a skeptic sub-agent's `rm -rf /tmp/tmp.*` deleted a live push's gate files.
# Bash tool commands only: scripts the command runs are not read. An unparseable command containing a removal is refused.
input="$(cat)"   # read stdin before any early exit, or the caller gets a broken pipe
case "$input" in *rm*|*unlink*|*-delete*|*remove*|*delete*) ;; *) exit 0 ;; esac
printf '%s' "$input" | python3 "$(dirname "$0")/../lib/gate_rm_glob_var.py"
[ $? = 2 ] && exit 2
exit 0

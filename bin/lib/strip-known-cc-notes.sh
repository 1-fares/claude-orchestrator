#!/usr/bin/env bash
# strip-known-cc-notes.sh -- stdin -> stdout, minus the known Claude Code start-up note that floods captured stderr.
#
# Every `claude` start prints a note about the deny rule `Bash(git push * :**)` in .claude/settings.json (older builds:
# `Bash(git push * :*)`). The rule is correct; the note is noise. In a daemon that appends a model call's stderr to a
# log, it becomes the whole log, and a caller that quotes the last stderr line quotes the note instead of the real
# error.
#
# NARROW ON PURPOSE: a line is dropped only when it starts with the full fixed text of that one note. A note about any
# other rule, or an error line that merely mentions this rule, passes through. Run as a program, never sourced, so no
# daemon's self-reload list has to name it. Exit 0 also when every line was dropped (grep -v would say 1), so a caller's
# `|| fallback` fires only on a real failure. -a: a NUL or invalid byte must not turn the whole stream into "binary
# file matches".
command grep -a -v -E '^Permission deny rule \(\.claude/settings\.json\): Bash\(git push \* :\*\*?\) '
rc=$?
[ "$rc" -le 1 ] && exit 0
exit "$rc"

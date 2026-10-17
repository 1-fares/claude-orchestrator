#!/usr/bin/env bash
# bin/lib/strip-known-cc-notes.sh drops exactly the known `Bash(git push * :**)` start-up note and nothing
# else. The positive controls matter more than the drop: a filter that ate a real error would be worse than the noise.
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$repo/bin/lib/strip-known-cc-notes.sh"
fail=0
eq() { [ "$2" = "$3" ] && printf '  ok   %s\n' "$1" || { printf '  FAIL %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fail=1; }; }

# The two shapes Claude Code prints, verbatim.
n1='Permission deny rule (.claude/settings.json): Bash(git push * :**) has a :* that is not at the end, so it is matched as a * wildcard (the : is literal), not as the trailing :* prefix syntax. It already matches as a * wildcard; moving :* to the end would make it a literal prefix and change which commands match.'
n2='Permission deny rule (.claude/settings.json): Bash(git push * :*) mixes * with the trailing :* prefix syntax, so it is matched as a literal prefix (the * is not expanded) and matches only commands containing a literal * at that position. Use Bash(git push *) for wildcard matching.'
real='API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"weekly limit reached"}}'
other='Permission deny rule (.claude/settings.json): Bash(rm -rf * :**) has a :* that is not at the end'
mention='Error: hook refused Bash(git push * :**) for origin'

echo "drops the known note:"
eq "note :** dropped"            "$(printf '%s\n' "$n1" | "$F")" ""
eq "note :* dropped"             "$(printf '%s\n' "$n2" | "$F")" ""
eq "all-noise input exits 0"     "$(printf '%s\n%s\n' "$n1" "$n2" | "$F" >/dev/null; echo $?)" "0"
eq "empty input exits 0"         "$("$F" </dev/null >/dev/null; echo $?)" "0"
echo "keeps everything else (positive controls):"
eq "real error kept"             "$(printf '%s\n' "$real" | "$F")" "$real"
eq "note for another rule kept"  "$(printf '%s\n' "$other" | "$F")" "$other"
eq "error mentioning rule kept"  "$(printf '%s\n' "$mention" | "$F")" "$mention"
eq "real error survives between notes, order kept" \
   "$(printf '%s\n%s\n%s\n%s\n' "$n1" "$real" "$n2" "$mention" | "$F")" "$(printf '%s\n%s' "$real" "$mention")"
# Without -a, grep reads a NUL or invalid byte as BINARY, prints only "binary file matches" and
# exits 0, so every line (the real error too) vanished and the callers' || fallback never fired.
eq "NUL byte in input: real error still kept" \
   "$(printf 'a\0b\n%s\n%s\n' "$n1" "$real" | "$F" | tail -1)" "$real"
eq "invalid UTF-8 byte in input: real error still kept" \
   "$(printf '\377 junk\n%s\n%s\n' "$n1" "$real" | LC_ALL=en_US.UTF-8 "$F" | tail -1)" "$real"
eq "tail -1 after filtering is the real error" \
   "$(printf '%s\n%s\n' "$real" "$n1" | "$F" | tail -1)" "$real"

echo
if [ "$fail" = 0 ]; then echo "strip-known-cc-notes: ALL PASS"; else echo "strip-known-cc-notes: FAILED"; fi
exit "$fail"

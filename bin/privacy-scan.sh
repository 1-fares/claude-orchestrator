#!/usr/bin/env bash
# privacy-scan.sh: block private data from leaving this machine. This repo is
# public; CLAUDE.md ("Public repository: no private data") bans real home
# paths, identities, secrets, endpoints, and machine identifiers from tracked
# files. This scanner enforces that ban mechanically.
#
# Reads a unified diff on stdin and exits 1 if any added line carries a
# private-data pattern, printing every hit. Placeholders (`<your-handle>`,
# `user@example.com`, `~/...`, `$HOME`) pass.
#
# Allowlisting is PER MATCHED TOKEN, not per line: an allowlisted placeholder
# elsewhere on a line must never shield a real token on the same line
# (peer-review finding, 2026-07-11: a doc line renaming a real home path to
# the /home/user placeholder previously passed whole, because the placeholder
# exempted the entire line including the real path).
#
# WHAT THIS MISSED FOR FIVE MONTHS, and why --tree and the deny file exist
# (audit 2026-10-19). Scanning only ADDED DIFF LINES means the gate can never
# see what is already committed: it is a push gate, not an audit. And the
# pattern list had nothing for an organisation name, a product name, a
# deployment directory or a cloud resource id. So a private deployment's own
# names (its config directory, its install path under $HOME/projects/) sat in
# three commits of the public history, and four commit messages named the
# company, while every push passed clean. Two answers, both here:
#   --tree    scan every tracked file, so the repo can be AUDITED, not just
#             guarded at the moment of a push.
#   deny file an operator-supplied list of literal private names. It is read
#             from a gitignored path on purpose: writing "the company is called
#             X" into a public file to stop X from reaching that file is the
#             same leak by another route.
#
# WHY THERE IS NO PATTERN FOR AN INSTALL PATH. The leak was a deployment name
# under $HOME/projects/, and a pattern for that shape was written and then
# removed: it fired on this repo's own documented examples (~/projects/app,
# ~/projects/app-a, ~/projects/some-app) and nothing in the shape distinguishes
# an example name from a real one. A gate that cries on its own documentation
# is muted within a week, which is how the nine-day reviewer failure happened.
# Deployment names belong in the deny file, where the operator states them once.
#
# KNOWN HISTORICAL HITS, scanning this repo's own full history. Commit
# 1e301527 (2026-07-11) documents the per-token allowlist finding by quoting
# the two invented fixtures it was found with, an ad-hoc home path and a
# keyword assignment, so `git log --all -p | bin/privacy-scan.sh` reports two
# hits from that message. They are prose examples, not data, and they block
# nothing: the pre-push gate reads only the commits being pushed. New messages
# should quote the documented placeholders (/home/user, user@example.com,
# <angle-brackets>) so this does not grow, and this note deliberately does not
# repeat the literals.
#
# Known deliberate false positive: 48+ hex chars blocks 64-char SHA-256
# integrity hashes (lockfiles). That stays: real API keys are exactly that
# shape (a live 64-hex key is what this gate exists to stop). Allowlist a
# specific lockfile hash pattern here if one ever becomes routine.
#
# Usage:
#   git diff --cached | bin/privacy-scan.sh          # the staged diff
#   git diff origin/master..master | bin/privacy-scan.sh
#   git show <sha> | bin/privacy-scan.sh
#   git log --all -p | bin/privacy-scan.sh           # the whole history
#   bin/privacy-scan.sh --tree                       # every tracked file
#
# Env:
#   PRIVACY_DENY_FILE   deny list path (default: config/privacy-deny.local,
#                       gitignored). One POSIX ERE per line; '#' comments and
#                       blank lines ignored. Absent file is not an error.
#
# Wired as a pre-push gate by bin/hooks/pre-push (see that file to install).
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_FILE="${PRIVACY_DENY_FILE:-$repo/config/privacy-deny.local}"

mode=diff
case "${1:-}" in
  --tree) mode=tree ;;
  --help|-h)
    sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "privacy-scan: unknown argument '$1' (expected --tree or a diff on stdin)" >&2; exit 2 ;;
esac

# What counts as private (alternation, case-insensitive). Each alternative is
# written to capture ENOUGH SURROUNDING CONTEXT that the per-token allowlist
# below can judge the token alone (e.g. the ntfy match takes the full
# host+topic incl. any <placeholder> chars, not just "ntfy.sh/" + one char):
#   real home paths            /home/<user>, /Users/<user>
#   real email addresses       any user at any real domain
#   ntfy topics                [host.]ntfy.sh/<topic>
#   secret-bearing assignments api_key=..., bearer ..., password: ...
#   long hex blobs             48+ hex chars (API keys; git SHA-1 is 40, passes)
#   non-loopback IPs           n.n.n.n
#   cloud resource ids         i-, sg-, sgr-, vpc-, subnet-, ami-, vol-, snap-
#   account ids in ARNs        arn:aws:...:<12 digits>:
#   provider key/token values  AKIA/ASIA, gh[pousr]_, github_pat_, xox[baprs]-
#   private key blocks         -----BEGIN ... PRIVATE KEY-----
#   chat ids                   19:<id>@thread.tacv2 / @thread.v2
private_re='(/home/[a-z_][a-z0-9_-]+|/Users/[A-Za-z][A-Za-z0-9_-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[A-Za-z0-9.-]*ntfy\.sh/[A-Za-z0-9_#/<>-]+|(api[_-]?key|secret|password|bearer|token)["'"'"'[:space:]]*[:=][[:space:]"'"'"']*([A-Za-z0-9_/+-]*[0-9][A-Za-z0-9_/+-]*|[A-Za-z0-9_/+-]{8,}[[:punct:]]?$|[A-Za-z0-9_/+-]{12,})|[a-f0-9]{48,}|([0-9]{1,3}\.){3}[0-9]{1,3}|\b(i|sg|sgr|vpc|subnet|ami|vol|snap)-[0-9a-f]{8,17}\b|arn:aws[a-z-]*:[^: ]*:[^: ]*:[0-9]{12}:|\b(AKIA|ASIA)[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bxox[baprs]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY|19:[A-Za-z0-9_<>-]{8,}@thread\.(tacv2|v2))'

# What a MATCHED TOKEN may look like and still pass. Judged against the token
# only. Entries that could shield a longer real value are end-anchored, so a
# secret whose value merely STARTS with an allowlisted word is still caught.
# (.invalid/.test/.example/.localhost are IANA-reserved, unrouteable by design;
#  ntfy.sh/orch-example and /home/user are this repo's own documented
#  placeholders; <angle-bracket> placeholders mark doc examples.)
#
# CHAT IDS ARE NOW FAIL-CLOSED. The old list allowlisted the @thread.tacv2 and
# @thread.v2 SUFFIXES outright, so a real Teams channel id passed the gate
# untouched. Only a placeholder id passes now: a run of one repeated character
# (the a/b/c fixtures in bin/tests) or an <angle-bracket> marker. A real id is
# mixed-case base64-ish and matches neither.
#
# THE VALUE TEST, AND THE REGRESSION IT CAUSED ON THE WAY IN (2026-10-19).
# The alternative used to match any 8+ character value, which refused ordinary
# English: the deployment fork measured two blocked lines on 2026-08-05, one a
# sentence where a keyword was followed by an ordinary nine-letter word, the
# other a code comment where a keyword was followed by a hyphenated phrase. A
# gate that punishes people documenting auth teaches bypass. Its rule, ported
# here, is that the value must CONTAIN A DIGIT or RUN TO END OF LINE.
# Measured against this repo afterwards, that rule gave back a shape the old
# one caught: a keyword, a long value with no digit in it, and more words after
# it on the same line satisfies neither branch, so it passed. A secret is a
# secret wherever it sits on the line, so a third branch blocks any value of 12
# or more characters. A nine-letter English word still passes; a credential
# that short is not worth bending a gate for. The literals are in
# bin/tests/privacy-scan.test.sh, which is the one file allowed to carry them.
#
# TWO FALSE POSITIVES FIXED 2026-10-19, both found by writing the test table
# rather than by use. (a) The email alternative forbade dots inside the domain
# body, so an @users.noreply.github.com address matched as "@users.noreply" and
# `^noreply@` could never exempt it: the gate blocked this repo's own commit
# identity. Domains may now carry dots, and the full noreply form is allowed.
# (b) `token: Optional[str]` matched the secret-assignment alternative, because
# a Python type annotation has the shape of a secret being set. A value that is
# a bare built-in or typing name is now allowed; a quoted or random-looking
# value is not.
allow_re='(^token = token_file[[:punct:]]?$|^token": bus_token[[:punct:]]?$|<[a-z][a-z-]*>|@example\.(com|org|net)$|@[A-Za-z0-9.-]+\.(invalid|test|example|localhost)$|^noreply@|@users\.noreply\.github\.com$|^127\.0\.0\.1$|^0\.0\.0\.0$|^/home/user$|^docs\.ntfy\.sh|ntfy\.sh/orch-example$|cubic-bezier$|load_secret\(?$|^19:(a+|b+|c+|x+|y+|z+|0+|1+)@thread\.(tacv2|v2)$)'

# Operator deny list: literal private names that no pattern can guess. Read
# from a gitignored file so the public tree never has to carry them.
# FAIL CLOSED ON A DENY FILE THAT EXISTS BUT CANNOT BE READ. Silently running
# with the generic patterns alone is the worst outcome: the operator believes
# the deployment's names are guarded, one chmod or one typo in
# PRIVACY_DENY_FILE removes that guard, and every push still reports clean.
# An ABSENT file stays silent, because "no deployment configured" is a real and
# common state that cannot be told apart from a missing one.
deny_re=""
if [ -e "$DENY_FILE" ]; then
  if [ ! -r "$DENY_FILE" ]; then
    echo "privacy-scan: deny file exists but is not readable: $DENY_FILE" >&2
    echo "privacy-scan: refusing to scan with the deny list silently disabled." >&2
    exit 2
  fi
  if ! deny_re="$(grep -vE '^[[:space:]]*(#|$)' "$DENY_FILE" | paste -sd'|' -)"; then
    : # grep exits 1 when every line is a comment or blank; that is legitimate
  fi
fi

# Candidate lines, tagged with the file they land in.
#   diff mode: added lines, plus commit-message lines. bin/hooks/pre-push feeds
#   `git show <commit>`, whose message is indented four spaces and whose diff
#   follows; only '+' lines were read until 2026-10-19, which is why three
#   commit messages naming the deployment's company reached the public history
#   with every push reporting clean.
#   tree mode: every line of every tracked file, so already-committed data is
#   visible at all. Binary files are skipped by -I.
#
# POSITION DECIDES WHAT A LINE IS, which is how git writes a diff and the only
# rule that cannot be forged from content. Inside a hunk every line is content,
# whatever it looks like: a deleted line reading "-- a/x" is rendered "--- a/x"
# and an added line reading "++ b/y" is rendered "+++ b/y", so a commit can
# forge a header PAIR out of ordinary content. Measured 2026-10-19: under the
# earlier "+++ counts only after ---" rule, one deletion and one addition in a
# hunk re-attributed the rest of the diff to the exempt fixture path and an
# AKIA key passed. The hunk header's line counts are tracked now and headers
# are read only between hunks. A '+' line outside any hunk is still scanned, so
# a diff carrying no @@ headers is not silently skipped.
#
# THE EXEMPT PATH IS COMPARED AS A STRING, not matched as a pattern. It was a
# grep regex whose dots matched any character, so a file named
# bin/tests/privacy-scanXtestXsh inherited the exemption (measured the same
# day). awk compares it with == inside the parse.
fixture_file='bin/tests/privacy-scan.test.sh'

if [ "$mode" = tree ]; then
  if ! (cd "$repo" && git rev-parse --git-dir >/dev/null 2>&1); then
    echo "privacy-scan: --tree needs a git repository at $repo" >&2
    exit 2
  fi
  raw="$(cd "$repo" && git grep -nI '' -- . 2>/dev/null | awk -v fixture="$fixture_file" '
    {
      i = index($0, ":"); if (i == 0) next
      f = substr($0, 1, i - 1)
      rest = substr($0, i + 1)
      j = index(rest, ":"); if (j == 0) next
      if (f != fixture) print f ":" substr(rest, j + 1)
    }')"
else
  raw="$(awk -v fixture="$fixture_file" '
    function emit(line) { if (file != fixture) print file ":" line }
    BEGIN { old_rem = 0; new_rem = 0; file = "" }
    (old_rem > 0 || new_rem > 0) {
      c = substr($0, 1, 1)
      if (c == "+")       { new_rem--; emit(substr($0, 2)); next }
      else if (c == "-")  { old_rem--; next }
      else if (c == " ")  { old_rem--; new_rem--; next }
      else if (c == "\\") { next }
      old_rem = 0; new_rem = 0    # malformed hunk: re-read this line as a header
    }
    /^commit [0-9a-f]{7,}/ { file = ""; old_rem = 0; new_rem = 0; prevminus = 0; seen_hunk = 0; next }
    /^diff /               { file = ""; prevminus = 0; seen_hunk = 0; next }
    /^--- /                { prevminus = 1; next }
    # BOTH conditions guard a header: outside a hunk (above) AND paired with a
    # minus-minus-minus line. git always emits the pair, so requiring it costs
    # nothing, and it means a lone plus-plus-plus line cannot retarget the scan
    # even in a hand-made diff carrying no @@ header. No apostrophes in here:
    # the awk program sits inside a single-quoted shell string.
    # THE PATH IS THE WHOLE REST OF THE LINE, not field 2: a path containing a
    # space truncated at the first one, and a file named like the exempt
    # fixture plus a space and a word inherited the exemption (measured
    # 2026-10-19). A trailing tab and timestamp, which plain diff emits, is cut.
    # SEEN_HUNK: a file header cannot follow a hunk header inside one file
    # section. That invariant is what covers a COMBINED diff from a merge,
    # whose @@@ header the line counter does not read, so without it a merge
    # diff could still forge a header out of content.
    /^\+\+\+ / && prevminus && !seen_hunk {
      file = substr($0, 5)
      sub(/\t.*$/, "", file)
      sub(/^b\//, "", file)
      prevminus = 0
      next
    }
    /^@@/                  {
      prevminus = 0
      seen_hunk = 1
      h = $0; sub(/ @@.*$/, "", h)
      old_rem = 1; new_rem = 1
      if (match(h, /-[0-9]+,[0-9]+/))  { t = substr(h, RSTART, RLENGTH); split(t, pr, ","); old_rem = pr[2] + 0 }
      if (match(h, /\+[0-9]+,[0-9]+/)) { t = substr(h, RSTART, RLENGTH); split(t, pr, ","); new_rem = pr[2] + 0 }
      next
    }
    /^    /                { prevminus = 0; print "(commit message):" substr($0, 5); next }
    /^\+/                  { prevminus = 0; emit(substr($0, 2)); next }
                           { prevminus = 0 }
  ')"
fi

candidates="$(printf '%s\n' "$raw" | grep -iE "$private_re" || true)"
deny_hits=""
if [ -n "$deny_re" ]; then
  deny_hits="$(printf '%s\n' "$raw" | grep -iE "$deny_re" || true)"
fi

hits=""
if [ -n "$candidates" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    toks="$(printf '%s' "$line" | grep -oiE "$private_re" | grep -ivE "$allow_re" || true)"
    if [ -n "$toks" ]; then
      file="${line%%:*}"
      while IFS= read -r t; do
        hits="${hits}${file}: ${t}"$'\n'
      done <<EOF
$toks
EOF
    fi
  done <<EOF
$candidates
EOF
fi

if [ -n "$deny_hits" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    toks="$(printf '%s' "$line" | grep -oiE "$deny_re" || true)"
    if [ -n "$toks" ]; then
      file="${line%%:*}"
      while IFS= read -r t; do
        hits="${hits}${file}: ${t} (deny list)"$'\n'
      done <<EOF
$toks
EOF
    fi
  done <<EOF
$deny_hits
EOF
fi

if [ -n "$hits" ]; then
  if [ "$mode" = tree ]; then
    echo "privacy-scan: PRIVATE DATA in tracked files:" >&2
  else
    echo "privacy-scan: PRIVATE DATA in added lines — push/commit blocked:" >&2
  fi
  printf '%s' "$hits" | sed 's/^/  /' >&2
  echo "privacy-scan: sanitize (placeholders per CLAUDE.md) or, for a deliberate false positive, adjust allow_re in bin/privacy-scan.sh." >&2
  exit 1
fi
exit 0

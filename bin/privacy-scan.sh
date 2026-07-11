#!/usr/bin/env bash
# privacy-scan.sh: block private data from leaving this machine. This repo is
# public; CLAUDE.md ("Public repository: no private data") bans real home
# paths, identities, secrets, endpoints, and machine identifiers from tracked
# files. This scanner enforces that ban mechanically on ADDED diff lines.
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
# Known deliberate false positive: 48+ hex chars blocks 64-char SHA-256
# integrity hashes (lockfiles). That stays: real API keys are exactly that
# shape (a live 64-hex key is what this gate exists to stop). Allowlist a
# specific lockfile hash pattern here if one ever becomes routine.
#
# Usage:
#   git diff --cached | bin/privacy-scan.sh          # the staged diff
#   git diff origin/master..master | bin/privacy-scan.sh
#   git show <sha> | bin/privacy-scan.sh
#
# Wired as a pre-push gate by bin/hooks/pre-push (see that file to install).
set -uo pipefail

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
private_re='(/home/[a-z_][a-z0-9_-]+|/Users/[A-Za-z][A-Za-z0-9_-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}|[A-Za-z0-9.-]*ntfy\.sh/[A-Za-z0-9_#/<>-]+|(api[_-]?key|secret|password|bearer|token)["'"'"'[:space:]]*[:=][[:space:]"'"'"']*[A-Za-z0-9_/+-]{8,}|[a-f0-9]{48,}|([0-9]{1,3}\.){3}[0-9]{1,3})'

# What a MATCHED TOKEN may look like and still pass. Judged against the token
# only. Entries that could shield a longer real value are end-anchored, so a
# secret whose value merely STARTS with an allowlisted word is still caught.
# (.invalid/.test/.example/.localhost are IANA-reserved, unrouteable by design;
#  ntfy.sh/orch-example and /home/user are this repo's own documented
#  placeholders; <angle-bracket> placeholders mark doc examples.)
allow_re='(<[a-z][a-z-]*>|@example\.(com|org|net)$|@[A-Za-z0-9.-]+\.(invalid|test|example|localhost)$|^noreply@|^127\.0\.0\.1$|^0\.0\.0\.0$|^/home/user$|^docs\.ntfy\.sh|ntfy\.sh/orch-example$|cubic-bezier$|load_secret\(?$)'

# Added lines only (skip the +++ file header), tagged with the file they land
# in. Fast path: one grep prunes non-candidate lines; only candidates pay the
# per-line token extraction.
candidates="$(awk '
  /^\+\+\+ /   { file=$2; sub(/^b\//,"",file); next }
  /^\+/        { print file ":" substr($0,2) }
' | grep -iE "$private_re" || true)"

hits=""
if [ -n "$candidates" ]; then
  while IFS= read -r line; do
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

if [ -n "$hits" ]; then
  echo "privacy-scan: PRIVATE DATA in added lines — push/commit blocked:" >&2
  printf '%s' "$hits" | sed 's/^/  /' >&2
  echo "privacy-scan: sanitize (placeholders per CLAUDE.md) or, for a deliberate false positive, adjust allow_re in bin/privacy-scan.sh." >&2
  exit 1
fi
exit 0

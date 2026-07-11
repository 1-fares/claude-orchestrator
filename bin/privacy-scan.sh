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
# Usage:
#   git diff --cached | bin/privacy-scan.sh          # the staged diff
#   git diff origin/master..master | bin/privacy-scan.sh
#   git show <sha> | bin/privacy-scan.sh
#
# Wired as a pre-push gate by bin/hooks/pre-push (see that file to install).
set -uo pipefail

# What counts as private (one ERE per line, case-insensitive):
#   real home paths            /home/<user>, /Users/<user>
#   real email addresses       any user at any real domain
#   ntfy topics                ntfy.sh/<real-topic>
#   secret-bearing assignments api_key=..., bearer ..., password: ...
#   long hex blobs             48+ hex chars (API keys; git SHA-1 is 40, passes)
#   non-loopback IPs           n.n.n.n
private_re='(/home/[a-z_][a-z0-9_-]+|/Users/[A-Za-z][A-Za-z0-9_-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}|ntfy\.sh/[A-Za-z0-9]|(api[_-]?key|secret|password|bearer|token)["'"'"'[:space:]]*[:=][[:space:]"'"'"']*[A-Za-z0-9_/+-]{8,}|[a-f0-9]{48,}|([0-9]{1,3}\.){3}[0-9]{1,3})'

# What looks private but is a sanctioned placeholder or local-only value:
# (.invalid/.test/.example/.localhost are IANA-reserved, unrouteable by design;
#  ntfy.sh/orch-example and /home/user are this repo's own documented placeholders)
allow_re='(<your-handle>|<random>|<user>|<name>|<unit>|example\.(com|org|net)|@[A-Za-z0-9.-]+\.(invalid|test|example|localhost)|orchestrator@local|noreply@|127\.0\.0\.1|0\.0\.0\.0|/home/\$|/Users/\$|\$HOME|\$USER|x{8}|ntfy\.sh/orch-example|docs\.ntfy\.sh|/home/user[/"'"'"'[:space:]]|/home/user$|cubic-bezier\(|= *load_secret\()'

# Added lines only (skip the +++ file header), tagged with the file they land
# in so a hit is actionable.
hits="$(awk '
  /^\+\+\+ /   { file=$2; sub(/^b\//,"",file); next }
  /^\+/        { print file ":" substr($0,2) }
' | grep -iE "$private_re" | grep -ivE "$allow_re" || true)"

if [ -n "$hits" ]; then
  echo "privacy-scan: PRIVATE DATA in added lines — push/commit blocked:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "privacy-scan: sanitize (placeholders per CLAUDE.md) or, for a deliberate false positive, adjust allow_re in bin/privacy-scan.sh." >&2
  exit 1
fi
exit 0

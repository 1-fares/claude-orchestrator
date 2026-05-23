#!/usr/bin/env bash
# new-goal.sh: write a goal brief by answering a few questions. You only describe
# what you want and where the code is; the orchestrator turns that into concrete
# acceptance criteria, scope, team, and a verify command at its definition-of-
# ready gate (and confirms with you before any work starts).
#
# Interactive:     bin/new-goal.sh
# Non-interactive: bin/new-goal.sh --name N --workdir DIR --want "..." \
#                     [--notes "..."] [--team "..."]

set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

name="" workdir="" want="" notes="" team=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)    name="$2"; shift 2 ;;
    --workdir) workdir="$2"; shift 2 ;;
    --want)    want="$2"; shift 2 ;;
    --notes)   notes="$2"; shift 2 ;;
    --team)    team="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$name$workdir$want" ]; then
  echo "New goal. Answer a few questions; the orchestrator fills in the rest."
  echo
  read -rp "Short name (e.g. add-export-button): " name
  read -rp "Working tree (path to the code; blank = this clone): " workdir
  echo "What do you want built or changed? (end with an empty line)"
  want="$(while IFS= read -r l; do [ -z "$l" ] && break; printf '%s\n' "$l"; done)"
  read -rp "Constraints or must-haves? (optional): " notes
  read -rp "Team hint? (optional; blank = orchestrator decides): " team
fi

name="${name%.md}"
[ -n "$name" ] || { echo "name is required" >&2; exit 2; }
printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' \
  || { echo "invalid name '$name' (letters, digits, dash, underscore)" >&2; exit 2; }
[ -n "$want" ] || { echo "a description ('what I want') is required" >&2; exit 2; }

dest="$repo/goals/$name.md"
[ -e "$dest" ] && { echo "already exists: $dest" >&2; exit 1; }

cat > "$dest" <<EOF
# Goal: $name

## Working tree
${workdir:-(this clone)}

## What I want
$want

## Notes / constraints
${notes:-none}

## Team hint
${team:-let the orchestrator decide}
EOF

echo "wrote $dest"
echo "next: bin/start-orchestrator.sh goals/$name.md   then   bin/attach.sh   (say 'go')"

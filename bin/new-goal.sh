#!/usr/bin/env bash
# new-goal.sh: scaffold a new goal brief from the template.
# Deterministic file op; no reason to spend an LLM turn on a copy.
#
# Usage: bin/new-goal.sh <name>
# Prints the path of the created file.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:?usage: $0 <name>}"
name="${name%.md}"

if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$'; then
  echo "invalid goal name '$name' (use letters, digits, dash, underscore)" >&2; exit 1
fi

dest="$repo/goals/$name.md"
[ -e "$dest" ] && { echo "already exists: $dest" >&2; exit 1; }
cp "$repo/goals/_TEMPLATE.md" "$dest"
echo "$dest"

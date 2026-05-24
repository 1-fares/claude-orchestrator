#!/usr/bin/env bash
# md-lint.sh: markdown well-formed and conformant via markdownlint-cli2.
# Skips with a warning if neither npx nor markdownlint-cli2 is on PATH (a gate
# that cannot run is not a gate that should fail; the orchestrator should know).
#
# Usage:
#   bin/gates/md-lint.sh <path-or-glob> [--config <file>]

set -euo pipefail
target="${1:?usage: md-lint.sh <path-or-glob> [--config <file>]}"
shift || true
cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) cfg="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if command -v markdownlint-cli2 >/dev/null; then
  bin=markdownlint-cli2
elif command -v npx >/dev/null; then
  bin="npx --yes markdownlint-cli2"
else
  echo "md-lint: SKIP (markdownlint-cli2 not installed; install with: npm i -g markdownlint-cli2)" >&2
  exit 0
fi

if [ -n "$cfg" ]; then
  exec $bin --config "$cfg" "$target"
else
  exec $bin "$target"
fi

#!/usr/bin/env bash
# md-lint.sh: markdown well-formed and conformant via markdownlint-cli2.
# Exits 2 if neither npx nor markdownlint-cli2 is on PATH: a gate that could not
# run must not read as a pass in a verify: line (verify-unit.sh would log it green).
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
  echo "md-lint: FAIL, not run (markdownlint-cli2 not installed and no npx; install with: npm i -g markdownlint-cli2)" >&2
  exit 2
fi

if [ -n "$cfg" ]; then
  exec $bin --config "$cfg" "$target"
else
  exec $bin "$target"
fi

#!/usr/bin/env bash
# rubric-judge.sh: thin wrapper on llm-judge.sh for per-unit rubric scoring.
# Use this in a task brief's verify: line for a custom-rubric gate.
#
# Usage: bin/gates/rubric-judge.sh <artifact> <rubric.md> [--n K] [--model MODEL]

set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/llm-judge.sh" "$@" --gate rubric-judge

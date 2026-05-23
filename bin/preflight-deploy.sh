#!/usr/bin/env bash
# preflight-deploy.sh: deterministic failsafe before a release. Verifies the
# current git remote, branch, and (for the prod class) a human-set token against
# the goal-declared target, and refuses on any mismatch. Ports the global
# "verify the deploy target before acting" rule into the team. The deployment
# role must call this and not release if it fails.
#
# Usage:
#   bin/preflight-deploy.sh --remote <substr> --branch <name> [--env <label>] [--prod]
#
# --remote   substring the origin URL must contain (e.g. the repo name)
# --branch   the branch a release must be on
# --env      free label for the message (e.g. staging, prod)
# --prod     production class: additionally require ORCHESTRATOR_DEPLOY_OK=1
#            (a human sets this in the environment to authorize a prod release)
#
# Run from inside the target working tree. Exit 0 = clear to deploy.

set -uo pipefail

remote="" branch="" env="" prod=0
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) remote="$2"; shift 2;;
    --branch) branch="$2"; shift 2;;
    --env)    env="$2"; shift 2;;
    --prod)   prod=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$remote" ] && [ -n "$branch" ] || { echo "usage: preflight-deploy.sh --remote <substr> --branch <name> [--env <label>] [--prod]" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git tree: $PWD" >&2; exit 2; }

fail=0
url="$(git remote get-url origin 2>/dev/null || true)"
cur="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

case "$url" in
  *"$remote"*) echo "remote OK: origin contains '$remote'";;
  *) echo "REMOTE MISMATCH: origin='$url' does not contain '$remote'" >&2; fail=1;;
esac
if [ "$cur" = "$branch" ]; then echo "branch OK: on '$branch'"; else echo "BRANCH MISMATCH: on '$cur', expected '$branch'" >&2; fail=1; fi

if [ "$prod" -eq 1 ]; then
  if [ "${ORCHESTRATOR_DEPLOY_OK:-}" = "1" ]; then
    echo "prod authorization OK (ORCHESTRATOR_DEPLOY_OK=1)"
  else
    echo "PROD NOT AUTHORIZED: set ORCHESTRATOR_DEPLOY_OK=1 (human) to release to ${env:-prod}" >&2; fail=1
  fi
fi

if [ "$fail" -eq 0 ]; then echo "preflight PASS${env:+ ($env)}; clear to deploy"; else echo "preflight FAIL${env:+ ($env)}; do not deploy" >&2; fi
exit "$fail"

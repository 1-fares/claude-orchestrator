#!/usr/bin/env bash
# copilot/bin/team-env.sh — port of bin/team-env.sh for GitHub Copilot CLI
#
# Sourced by other copilot/bin/ scripts. Derives per-run env vars.
# Identical to the Claude Code version except:
#   - COPILOT_HOME replaces CLAUDE_HOME references in documentation
#   - No changes to logic; bus/tmux/state derivation is model-agnostic
#
# TODO(copilot-port): verify TEAM_TMUX_CONF works with copilot sessions
#   (confirm copilot CLI doesn't require a special tmux setup)

# Delegate to the original implementation — it is fully generic
# shellcheck source=../../bin/team-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/team-env.sh"

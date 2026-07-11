#!/usr/bin/env bash
# isolate.sh: mandatory first source for every test under bin/tests/.
#
# Forces per-test isolation REGARDLESS of inherited environment. The failure
# class this closes (2026-07-11 incident): a role session carries the live
# run's TEAM_RUN_ID / TEAM_TMUX / TEAM_SESSION in its environment; a test run
# from that session inherits them, sources team-env.sh, derives the LIVE run's
# dir and session, and its cleanup trap (`rm -rf "$TEAM_DIR"`, kill-session)
# destroys the live run. team-env's TEAM_DIR guard cannot catch this — the
# inherited env is internally consistent, so nothing looks overridden.
#
# Usage, as the FIRST lines of a test, before anything touches team-env:
#   repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#   . "$repo/bin/tests/lib/isolate.sh"     # exports fresh TEAM_RUN_ID/TEAM_TMUX
#   . "$repo/bin/team-env.sh"              # now derives throwaway names
#
# After sourcing team-env, call isolate_assert to hard-verify the derivation
# landed on the throwaway names (belt and braces):
#   isolate_assert

export TEAM_RUN_ID="test$$${RANDOM}"
export TEAM_TMUX="tt${$}"
unset TEAM_DIR TEAM_SESSION TEAM_PORT INTER_SESSION_PORT TEAM_DIR_ALLOW_OVERRIDE

isolate_assert() {
  case "${TEAM_DIR:-}" in
    *".team-test$$"*) : ;;
    *) echo "isolate.sh: TEAM_DIR='${TEAM_DIR:-}' is not the throwaway test dir; refusing to run" >&2
       exit 99 ;;
  esac
  case "${TEAM_TMUX:-}" in
    tt$$) : ;;
    *) echo "isolate.sh: TEAM_TMUX='${TEAM_TMUX:-}' is not the throwaway test socket; refusing to run" >&2
       exit 99 ;;
  esac
}

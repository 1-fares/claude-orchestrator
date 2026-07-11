# Incident: a test's cleanup destroyed a live run (2026-07-11)

## What happened

Mid-run, a live team's tmux session and its entire run-state directory
(`.team-<run-id>/`: ledger, task briefs, health, audit) disappeared at once.
Every role process died with the session. The working tree survived because
the team had committed continuously; the only lost artifact was one
transcript that had been verified but not yet written to disk.

## Root cause

Every role session carries the live run's `TEAM_RUN_ID`, `TEAM_TMUX`,
`ORCH_HOME`, and `INTER_SESSION_PORT` in its environment (exported by the
spawn path so the role's gates and helpers resolve the right run). A tooling
role wrote and ran a test that sourced `bin/team-env.sh` WITHOUT first
overriding those, so the test derived the LIVE run's `TEAM_DIR`, session,
and socket. Its cleanup (`trap 'rm -rf "$TEAM_DIR"; tmux kill-session ...'
EXIT`) then destroyed the live run when the test exited.

The existing `TEAM_DIR` override guard in `team-env.sh` could not catch
this: nothing was overridden — the inherited environment was internally
consistent, so every derived name pointed, correctly and fatally, at the
live run.

Timeline signature to recognise it by: all `tmux-spawn-*.scope` units for
the session report "Consumed ... CPU time" within seconds of each other in
the user journal (the panes dying), the session disappears (a session with
zero windows dies), and the run dir is gone with no `CRASH-DETECTED.md`
(the tmux-watchdog had nowhere left to write one).

## Fixes (this commit)

1. **`bin/tests/lib/isolate.sh`** — mandatory first source for every test:
   exports throwaway `TEAM_RUN_ID`/`TEAM_TMUX`, unsets every inherited team
   variable, and provides `isolate_assert` to verify the derivation landed
   on throwaway names.
2. **`bin/team-env.sh` tripwire** — if any caller in the `BASH_SOURCE`
   chain is under `bin/tests/` and `TEAM_RUN_ID` is not a test id, it
   prints the isolate.sh instruction and hard-exits (97). `exit`, not
   `return`: a sourcing test must die, not continue with partial names.
3. **Role tripwire in `bin/reset.sh` / `bin/cleanup.sh --force`** — a shell
   with `ORCH_HOME` set is a team role session; both scripts refuse
   destructive operation there (exit 96) unless `RESET_CONFIRM=yes`.
   Dry-run `cleanup.sh` stays allowed anywhere.

## Recovery playbook (what worked)

1. Confirm the working tree: `git status` / `git log` in the target repo —
   the tree is the only durable state; the ledger is reconstructable.
2. Identify what was in flight from the last bus traffic and commits.
3. Stop the dead run's leftover daemons (their pidfiles died with the dir;
   match by `ps` args) and any stale sessions on the team socket.
4. Write a recovery goal file stating the verified tree baseline, the
   remaining units, and the original hard rules; launch a fresh run with a
   new `TEAM_RUN_ID`.
5. Brief the new team to commit early and often.

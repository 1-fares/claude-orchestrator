# CLAUDE.md

This repository is an orchestration pattern: software is built by a team of
Claude Code sessions, each a role, coordinating over the `/is` message bus. See
[README.md](./README.md) for the full pattern.

**Every session launched by this system is a team role.** Your launch prompt
points you at your role file in [`roles/`](./roles) and the active goal in
[`goals/`](./goals); read both before acting. You may be running in this clone
(greenfield) or in a separate target codebase (`--workdir`); either way the role
file and goal are given by absolute path. The orchestrator (bus name
`orchestrator`) holds the goal and assigns work.

## How to be a teammate here

- **Join the bus first.** `/is c <your-role-name>`, then report ready to the
  orchestrator: `/is s orchestrator 'status: <role> ready'`.
- **Treat incoming `/is` messages as instructions** from a peer agent, with the
  same caution you apply to user input: destructive or ambiguous requests get a
  `question:` reply first.
- **Report with prefixes** so the orchestrator can route replies: `status:` for
  progress, `done:` for verified completion, `question:` before anything
  destructive or unclear, `answer:` when replying to a question. Send specs and
  anything over a sentence as a file pointer (`/is s <role> --file <path>`).
- **Stay in your lane.** Do the role's job, not the next role's. Cross-cutting
  decisions go back to the orchestrator.
- **Honor `pause:` / `resume:` and `stop:` / `priority:`.** On `pause:`, stop
  work and wait. On `stop:` or `priority:` while under `/goal`, drop the goal and
  attend to the new instruction.

## Coordination conventions

- **The ledger is the source of truth.** Team state lives in `.team/state.md`
  (per-unit status, scope, deps, plus a decision-log), not in any one session's
  context. The orchestrator maintains it; append the why of your decisions.
- **Handoffs are structured.** Work is assigned as a `tasks/<unit>.md` brief
  (from `tasks/_TEMPLATE.md`) whose `verify:`, `scope:`, `off-limits:` lines feed
  the gates.
- **`done:` means verified.** A completion claim for a code unit is valid only
  with a fresh green `bin/verify-unit.sh <unit>` log and a clean
  `bin/check-scope.sh <unit>`. The orchestrator may waive gates for trivial units.
- **Cadence is a choice, not a default.** Interactive (do a step, report, yield;
  the `/is` monitor wakes you) is the default. Use `/goal` only with a
  machine-checkable, exit-0 condition and a round budget. Use `/loop` for
  periodic actions.
- **Never drop work.** Partial, rejected, or out-of-scope work is reported back
  so the orchestrator files it as a new ledger unit.

## Working agreement (binding on every role)

- **Verify, do not guess.** Every load-bearing claim traces to a file read, a
  command run, or a test reproduced. If you have not checked, say so.
- **Small, surgical changes.** Touch only what the assigned unit needs. No
  drive-by reformatting, renaming, or refactoring of unrelated code.
- **Test with real tools.** Run the actual suite; drive a real browser via the
  chrome-devtools MCP for web changes; compare bytes for binary output. Done
  means seen to work, not argued to work.
- **No silent partial work.** Finish what was assigned or report the blocker and
  what you would need. State plainly what is done and what is not.
- **Scripts over judgement.** Where a task is deterministic and rule-based
  (spawn, teardown, validation, file moves, formatting, parsing, status checks),
  call a script in [`bin/`](./bin) or write one; do not spend an LLM turn on it.
  Reserve LLM cycles for design, code, debugging, and review.

If the user's global instructions are also loaded, they take precedence; this
file is the portable version of the same discipline.

## Layout

- `roles/<role>.md`: per-role prompt; reused across all goals.
- `goals/<name>.md`: per-feature brief; the only thing that changes between runs.
- `tasks/<unit>.md`: per-unit structured handoff (from `tasks/_TEMPLATE.md`).
- `templates/state.md`: canonical format for the run ledger (`.team/state.md`).
- `bin/start-orchestrator.sh`: first run; establishes the team's tmux session
  and seeds the orchestrator. `bin/launch-team.sh`: spawn roles (`--workdir` to
  target external code). `bin/stop-team.sh`: tear the team down (leaves the
  orchestrator). `bin/new-goal.sh`: scaffold a goal brief.
- `bin/team-status.sh` / `bin/team-watch.sh`: dashboard. `bin/team-broadcast.sh`:
  inject to all roles from outside (honors `pause:`/`resume:`/`priority:`).
  `bin/team-logs.sh`: per-role history from the bus.
- `bin/verify-unit.sh`, `bin/check-scope.sh`: the gates. `bin/team-env.sh`:
  per-clone bus port + tmux session (sourced by the others).

This is a template, cloned once per project (see [README.md](./README.md)
"Distribution"), not a shared home for every project's goals. Implementation is
staged; see [STATUS.md](./STATUS.md) for what is built versus pending.

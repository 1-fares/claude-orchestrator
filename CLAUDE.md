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
- **`$ORCH_HOME` locates the team's files.** The orchestrator clone is exported
  as `$ORCH_HOME` in every role session. Run gates
  (`$ORCH_HOME/bin/verify-unit.sh`, `$ORCH_HOME/bin/check-scope.sh`) and write
  team artifacts (`$ORCH_HOME/.team/...`) by that path; it resolves whether you
  run in the clone (greenfield) or a separate `--workdir` tree. Your own code
  changes go in your working tree (your cwd).

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
- **Python uses `uv`.** For any Python work, use `uv`: `uv init` for a new
  project, `uv add <pkg>` (and `uv add --dev <pkg>`) for dependencies, and
  `uv run <cmd>` to run anything (e.g. `uv run pytest`, `uv run python app.py`).
  Do not use bare `pip`, `python -m venv`, or a global interpreter. Verify
  commands run under `uv run` so dependencies resolve.

If the user's global instructions are also loaded, they take precedence; this
file is the portable version of the same discipline.

## Layout

- `roles/<role>.md`: per-role prompt; reused across all goals.
- `goals/<name>.md`: per-feature brief; the only thing that changes between runs.
- `tasks/<unit>.md`: per-unit structured handoff (from `tasks/_TEMPLATE.md`).
- `templates/state.md`: canonical format for the run ledger (`.team/state.md`).
- `bin/run.sh`: the one-command entry point. Starts the orchestrator and attaches;
  the orchestrator then asks for the working tree and goal **in the session**
  (visible, recorded, recoverable), not via shell prompts. Recovery-aware: offers
  to reattach a live run, or clean a misfired one (via `cleanup.sh`) before
  starting. Power/scripted args still pre-seed target+goal. Composes the scripts
  below.
- `bin/new-project.sh`: scaffold a brand-new target repo. `bin/new-goal.sh`: a
  short questionnaire that writes a goal brief (you describe the goal; the
  orchestrator fills in acceptance/scope/team/verify at the ready-gate).
- `bin/start-orchestrator.sh`: first run; by default runs the orchestrator in
  your terminal (foreground) and spawns roles into tmux (`--tmux` puts the
  orchestrator in tmux too). `bin/launch-team.sh`: spawn roles (`--workdir` to
  target external code). `bin/attach.sh`: attach to the team tmux session.
- `bin/stop-team.sh`: end the roles. `bin/reset.sh`: clean slate (ends
  everything, clears `.team/`). `bin/panic.sh`: emergency stop. `bin/cleanup.sh`:
  recover from a misfire, reaps orphaned role sessions the others miss (a lost
  tmux session, a launch with no `.team/active`), dry-run by default, `--force`
  to apply, `--purge` for config/artifacts, `--include-unsigned` for orphans not
  attributable to this clone.
- The team runs on a dedicated tmux socket (`-L orchestrator`, no user config),
  isolated from your default tmux server and its plugins (e.g.
  resurrect/continuum). Use `bin/attach.sh` / `bin/team-status.sh`, not a plain
  `tmux attach`.
- `bin/team-status.sh` / `bin/team-watch.sh`: dashboard. `bin/team-broadcast.sh`:
  inject to all roles from outside (honors `pause:`/`resume:`/`priority:`).
  `bin/team-logs.sh`: per-role history from the bus.
- `bin/verify-unit.sh`, `bin/check-scope.sh`: the gates. `bin/team-env.sh`:
  per-clone bus port + tmux session, with optional **per-run isolation** when
  `TEAM_RUN_ID` is set (bin/run.sh allocates one per invocation and spawned
  children inherit it), so parallel teams in one clone get their own port,
  session, and state dir (`.team-<run-id>/`) and do not collide on names. No
  `TEAM_RUN_ID` = today's per-clone behavior (state in `.team/`).
- `bin/preflight-deploy.sh`, `bin/panic.sh`, `bin/watchdog.sh`, `bin/worktree.sh`,
  `bin/trust-workdir.sh` (pre-accept the workspace-trust prompt for a dir).

This is a template, cloned once per project (see [README.md](./README.md)
"Distribution"), not a shared home for every project's goals. Implementation is
staged; see [STATUS.md](./STATUS.md) for what is built versus pending.

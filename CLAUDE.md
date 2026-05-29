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

- **The ledger is the source of truth.** Team state lives in `$TEAM_DIR/state.md`
  (`.team/state.md` in legacy single-team mode, `.team-<run-id>/state.md` per run,
  so concurrent runs in one clone never share a ledger): per-unit status, scope,
  deps, a decision-log, and a `## roster` of add/retire events, not in any one
  session's context. The orchestrator maintains it; append the why of your
  decisions. Likewise write briefs to `$TEAM_DIR/tasks/<unit>.md` and all role
  artifacts under `$TEAM_DIR/`.
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
- **`$ORCH_HOME` locates the team's code; `$TEAM_DIR` locates this run's state.**
  Both are exported in every role session. Run gates
  (`$ORCH_HOME/bin/verify-unit.sh`, `$ORCH_HOME/bin/check-scope.sh`) from
  `$ORCH_HOME`, but write all team artifacts (specs, evidence, logs, the ledger,
  briefs) under `$TEAM_DIR/...`, never `$ORCH_HOME/.team/...` directly: `$TEAM_DIR`
  is per-run (`.team-<run-id>/`, or `.team/` in legacy single-team mode), so
  parallel runs in one clone do not overwrite each other's state. `$ORCH_HOME`
  resolves whether you run in the clone (greenfield) or a separate `--workdir`
  tree. Your own code changes go in your working tree (your cwd).

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
- **Push the work branch to origin; it is not gated.** Pushing the team's work or
  integration branch to `origin` (to back it up, open a PR, or trigger CI) is a
  routine, operator-authorized step, not a human handoff. Do not finish a unit
  leaving its branch unpushed and report the push as a "deliberate handoff" or
  "not done by design", that is the failure this rule exists to stop; push it.
  This standing authorization is deliberate and overrides the cautious default of
  pushing only on request. The human gate applies only to: (a) merging into a
  protected default or production branch, (b) production deploys (see
  `bin/preflight-deploy.sh`), and (c) destructive pushes (force-push, history
  rewrite, branch deletion), each of which still warrants a `question:` first.
- **Scripts over judgement.** Where a task is deterministic and rule-based
  (spawn, teardown, validation, file moves, formatting, parsing, status checks),
  call a script in [`bin/`](./bin) or write one; do not spend an LLM turn on it.
  Reserve LLM cycles for design, code, debugging, and review.
- **Python uses `uv`.** For any Python work, use `uv`: `uv init` for a new
  project, `uv add <pkg>` (and `uv add --dev <pkg>`) for dependencies, and
  `uv run <cmd>` to run anything (e.g. `uv run pytest`, `uv run python app.py`).
  Do not use bare `pip`, `python -m venv`, or a global interpreter. Verify
  commands run under `uv run` so dependencies resolve.
- **Default to act on tactical decisions.** Idle time waiting on the
  orchestrator or operator is a defect, not a courtesy. Inside an already-agreed
  brief, decide locally and continue. Escalate as a `question:` only on
  strategic scope change, destructive or irreversible ops, novel creative
  direction not yet steered, security or auth surface change, a hard blocker, or
  an internally contradictory brief. When unclear, the default is act; the
  operator can rebrief and any rework is a normal follow-up unit, never the
  team's wall clock. Full rationale and the ask pattern
  (`"I'm doing X, rationale: ..., saying so unless you object"`) in
  `docs/default-to-act.md`. Binds the orchestrator and the communicator most
  strongly; working roles apply the same spirit toward the orchestrator.
- **Pragmatic solutions over dead-ends.** When something fails or is blocked,
  do not stop at "cannot be done; the API / permissions / owner will not allow
  it." Diagnose the cause, then build or propose the path a competent human
  tool would offer: the specific reason, the actor who can unblock it, and the
  concrete next action. Where it is safe and in scope, automate that action
  behind an explicit, approved step rather than leaving it as advice. A correct
  "this is denied" is half an answer; the useful half is "here is exactly why,
  and here is how to resolve it." This binds error envelopes, tool design, and
  investigation reports alike: an investigation that ends "not our bug, ask
  someone else" is not finished until it has also asked "what would make this
  work next time, and can we provide it?" Distinguish a true hard limit (which
  is reported plainly) from a limit that is merely inconvenient to lift (which
  is engineered around).

If the user's global instructions are also loaded, they take precedence; this
file is the portable version of the same discipline.

## Layout

- `roles/<role>.md`: per-role prompt; reused across all goals.
- `goals/<name>.md`: per-feature brief; the only thing that changes between runs.
- `tasks/<unit>.md`: per-unit structured handoff (from `tasks/_TEMPLATE.md`).
- `templates/state.md`: canonical format for the run ledger
  (`$TEAM_DIR/state.md`, i.e. `.team-<run-id>/state.md` per run, or `.team/state.md`
  in legacy single-team mode).
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
- `bin/add-role.sh` / `bin/retire-role.sh`: dynamic team scaling (B9). Add one
  role to a LIVE team (enforces a soft, operator-chosen team-size cap, default 12,
  custom, or uncapped, from `$TEAM_DIR/max-team-size` or `MAX_TEAM_SIZE`; refuses
  double-spawn,
  reuse-before-spawn hint, decision-log + roster line, ntfy) or retire one role
  (graceful single-role teardown scoped to that role, refuses if it owns
  in-progress units unless `--force` re-files them, archives to `retired/`). Both
  reuse the shared single-role spawn/teardown discipline in `bin/lib/` and the
  same hard safety scoping as `cleanup.sh`. Prefer a bus `pause:` over retire for
  a temporarily-idle role.
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
- `bin/api-watchdog.sh`: the team's liveness watchdog. Covers two failure modes
  in one scan loop. (a) **API-stall:** a role idled at the prompt by a transient
  Anthropic rate-limit / network error, auto-sends `try again` with exponential
  backoff (default 30/60/120/300/600s, max 5 retries). (b) **Stuck (wedged):** a
  role that is busy (spinner up) but shows no liveness for `STUCK_THRESHOLD_SEC`
  (default 480s), it is hung on a tool call (classically a chrome-devtools MCP
  call after the debug Chrome dies). Liveness = the pane content changed OR the
  streaming token counter advanced; the token counter climbs during a long
  legitimate think (so a think is not mistaken for a wedge) but freezes on a
  hung call. The elapsed timer is ignored, it ticks even when wedged. An
  API-stall detector alone cannot see this, a spinner reads as healthy, so a
  wedge silently stalls the run. Recovery ladder: first an Escape + nudge to the role's own pane
  (gentle, autonomous, preserves context), then after `STUCK_MAX_NUDGES`
  (default 2) failed attempts it marks the role `stuck-giveup` and messages the
  orchestrator to retire+respawn it (or writes `PENDING.md` if the stuck role is
  the orchestrator itself). Writes per-role state to `$TEAM_DIR/health/<role>.json`
  (`active`/`stalled-api`/`stuck`/`stuck-giveup`/`give-up`) and pushes `ntfy` on
  state changes. The pure pane detectors live in `bin/lib/watchdog-detect.sh`
  (unit-tested by `bin/tests/watchdog-detect-test.sh`; end-to-end recovery by
  `bin/tests/watchdog-stuck-integration-test.sh`). Started automatically by
  `launch-team.sh`; cleaned up by `stop-team.sh` / `panic.sh` / `cleanup.sh`.
  Pure shell, makes no Claude API call, so cannot itself be rate-limited. Tier-3
  awareness is pull-only: the orchestrator reads `$TEAM_DIR/health/` to decide.
  Patterns at `bin/api-watchdog.patterns`. Disable the whole watchdog with
  `API_WATCHDOG_DISABLED=1`, or just stuck detection with `STUCK_WATCHDOG_DISABLED=1`.
- `bin/tmux-watchdog.sh`: detects the tmux server itself going away (systemd
  scope cleanup, WSL2 suspend/resume, daemon-reload from other tooling) and
  flips `$TEAM_DIR/health/tmux.json` to `state=crashed`, drops
  `$TEAM_DIR/CRASH-DETECTED.md` with the recovery command, and pushes `ntfy`.
  Also takes a forensic snapshot of every window every 60s into
  `$TEAM_DIR/snapshots/`. Does NOT auto-restart the team; recovery still goes
  through the operator. Auto-started by `launch-team.sh`. Disable with
  `TMUX_WATCHDOG_DISABLED=1`. Background and recovery flow in
  `docs/incident-2026-05-26-tmux-scope-cleanup.md`.
- `bin/communicator.sh`: opens a Claude Code session in the `communicator` role,
  the team's two-way operator liaison (spec at `roles/user-communicator.md`).
  One bus identity per run, multiple front-ends share state under
  `$TEAM_DIR/comm/`. Idempotent: a second invocation reattaches the existing
  tmux window. `bin/dashboard.sh`: read-only HTTP viewer (force-graph + stats +
  operator chat panel for the communicator) on `127.0.0.1`. Auto-started by
  `launch-team.sh`; URL in `$TEAM_DIR/dashboard.url`. Disable with
  `DASHBOARD_DISABLED=1`.
- **Non-code substrate.** `roles/` ships generic non-code roles, structural
  pipeline references that codify lane discipline (`researcher`, `writer`,
  `editor`, `fact-checker`, `copy-editor`, `peer-reviewer`, `doc-integrator`),
  plus three cross-cutting legal references (`paralegal`, `lawyer`,
  `swiss-law-specialist`). Area specialists (e.g. `employment-lawyer1`,
  `tenancy-lawyer1`, `market-analyst1`) are NOT predefined: the orchestrator
  authors them on-the-fly from `roles/_TEMPLATE.md` per goal, so the operator is
  free to pursue any topic with any role names without growing the curated set.
  A pluggable **gate library** at `bin/gates/` wraps non-binary checks as exit-0
  commands for non-code units (`structure`, `link-live`, `cite-resolve`,
  `md-lint`, `office-wellformed`, `llm-judge`, `rubric-judge`, `cite-support`);
  a goal's `tasks/<unit>.md` `verify:` line wires one of these.

This is a template, cloned once per project (see [README.md](./README.md) for
the install and run flow), not a shared home for every project's goals.
Implementation is staged; see [STATUS.md](./STATUS.md) for what is built versus
pending.

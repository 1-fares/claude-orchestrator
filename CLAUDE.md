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

## Public repository: no private data (binding)

This repo is public (`github.com/1-fares/claude-orchestrator`). It is a generic
template; nothing about any operator's real machine, identity, or projects
belongs in tracked files. Before committing, every role and the orchestrator must
keep private data out of the tree.

- **Never commit, and scrub before staging:** real usernames or home paths
  (`/home/<user>/...`, `/Users/<user>/...`; use `~/...` or `$HOME` instead), real
  email addresses, employer or client names, real project/repo names from the
  operator's machine, secrets of any kind (API keys, tokens, bearer tokens,
  passwords, ntfy topics, webhook URLs, signing keys), non-local IPs or private
  endpoints, and machine-specific identifiers (tmux socket names tied to a host,
  absolute deployment paths).
- **Goals, task briefs, and run state are private by default.** A real
  `goals/<name>.md` or `tasks/<unit>.md` carries endpoints, paths, and app
  internals. `.gitignore` already ignores `goals/*`, `tasks/*`, `.team/`,
  `.team-*/`, `tasks-archive/`, `project.conf`, `team.tmux.conf`, and
  `RESUME-HERE.md`, with only the curated `_TEMPLATE.md` and demo files
  allowlisted. Do not `git add -f` a real brief or run dir, and do not add new
  allowlist exceptions for anything that is not a deliberately generic demo.
- **Use placeholders in docs and examples:** `~/projects/app-a`, `<your-handle>`,
  `https://ntfy.sh/orch-<your-handle>-<random>`, `user@example.com`. Bug reports
  and incident notes get the same scrub: sanitize observed paths, goal names, and
  working trees to generic stand-ins before committing.
- **The only intentional identity in tracked files** is the public GitHub handle
  `1-fares` and the `LICENSE` copyright line. Do not introduce any other.
- **Before any commit, sweep the staged diff:**
  `git diff --cached | bash bin/privacy-scan.sh` (exit 0 = clean; it prints
  every hit). The same scan, plus the author and committer identity, runs as a
  pre-push gate over every outgoing commit once the hook is installed per clone:
  `ln -sfn ../../bin/hooks/pre-push .git/hooks/pre-push`, or
  `git config core.hooksPath bin/hooks`, which disables every other hook in
  `.git/hooks` (`docs/ENFORCEMENT.md`). A hit that is a genuine placeholder
  false positive is added to `allow_re` in `bin/privacy-scan.sh`, never
  bypassed with `--no-verify`.

## How to be a teammate here

- **Join the bus first,** with bus-inbox (never a Monitor on client.py; full text:
  `docs/BUS-INBOX.md`). `B="python3 $ORCH_HOME/bin/bus-inbox.py"`. Once: `$B start <name>`.
  Then Bash run_in_background: `$B wait <name> 7200`. When it completes, in ONE response:
  Read its output AND re-arm. HEARTBEAT: nothing to do. rc 2 LISTENER DEAD: start, re-arm,
  `status:` to the orchestrator. rc 3: a reader is armed, do not re-arm. After a /clear or
  compaction: `$B status <name>`; `reader=none` = arm. If a brief says `/is c`: do this
  instead (TaskStop any Monitor first). Then report ready to the orchestrator:
  `/is s orchestrator 'status: <role> ready'`.
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
- **Compact when the watchdog asks.** When a `[compaction-watchdog]` message asks
  you to compact, finish the current step, write your state, run the `touch`
  command it gives, and end your turn; the watchdog then sends `/compact`. A
  session cannot run `/compact` itself.

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
  the bus reader wakes you) is the default. Use `/goal` only with a
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
- **Tests are isolated, always.** Any test under `bin/tests/` sources
  `bin/tests/lib/isolate.sh` BEFORE `bin/team-env.sh` (throwaway
  `TEAM_RUN_ID`/`TEAM_TMUX`; `isolate_assert` after). team-env hard-exits a
  test caller with a non-test run id: an inherited live id is how a test's
  cleanup once wiped a live run
  (`docs/incident-2026-07-11-test-cleanup-wiped-live-run.md`). Run the suite
  with `bash bin/tests/run-all.sh` (one file at a time; file names select a
  subset). Roles never run `reset.sh` or `cleanup.sh --force`; both refuse
  inside a role session.
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

Detail for each entry: the README section named, a doc, or the script header.

- `roles/<role>.md`: per-role prompt; reused across all goals.
- `goals/<name>.md`: per-feature brief; the only thing that changes between runs.
- `tasks/<unit>.md`: per-unit structured handoff (from `tasks/_TEMPLATE.md`).
- `templates/state.md`: canonical format for the run ledger `$TEAM_DIR/state.md`.
- `docs/model-policy.md`: per-role model tiers (`model_for()` in
  `bin/lib/team-spawn.sh`; overrides `TEAM_MODEL_<ROLE>`, `TEAM_MODEL_TOP`,
  `TEAM_MODEL_DEFAULT`; each role's model is recorded in `$TEAM_DIR/models/<role>`)
  and the token-economy disciplines that keep top-tier roles affordable.
- Operator entry points (README "Run a goal", "Drive the team"): `bin/run.sh`,
  `bin/new-project.sh`, `bin/new-goal.sh`, `bin/start-orchestrator.sh` (first run
  and recovery), `bin/launch-team.sh` (`--workdir` for external code),
  `bin/attach.sh` (the team has its own tmux socket, `-L orchestrator`: never a
  plain `tmux attach`), `bin/stop-team.sh`, `bin/reset.sh` (clears this run's
  `$TEAM_DIR`), `bin/panic.sh`, `bin/cleanup.sh` (dry-run unless `--force`).
- `bin/add-role.sh` / `bin/retire-role.sh`: grow or shrink a live team by one
  role (README "Dynamic team scaling"). Prefer a bus `pause:` over retire for a
  temporarily idle role.
- `bin/team-status.sh` / `bin/team-watch.sh`: status view. `bin/team-broadcast.sh`:
  inject to all roles from outside (honors `pause:`/`resume:`/`priority:`).
  `bin/team-logs.sh`: per-role history from the bus.
- `bin/verify-unit.sh`, `bin/check-scope.sh`: the gates. `bin/team-env.sh`: bus
  port, tmux session and `$TEAM_DIR`, per run when `TEAM_RUN_ID` is set (README
  "Parallel runs in one clone").
- `bin/tools/`: small coding helpers a role runs as `$ORCH_HOME/bin/tools/<name>`
  instead of re-deriving boilerplate: `probe-env.sh` (a repo's build/test/lint and
  a `verify:` line), `impact-scan.sh` (reverse dependencies of a file),
  `red-green.sh` (the tester's fail-then-pass evidence pair), `diff-summary.sh`
  (compact change summary). See `bin/tools/README.md`.
- `bin/preflight-deploy.sh`, `bin/watchdog.sh`, `bin/worktree.sh` (`remove`
  refuses a worktree with uncommitted changes unless `--force`),
  `bin/trust-workdir.sh` (pre-accept the workspace-trust prompt for a dir).
- Supervisor daemons, pure shell, started and stopped with the team (README
  "Daemon lifecycle"): `bin/api-watchdog.sh` (API-error and usage-limit stalls,
  wedged and prompt-blocked roles; state in `$TEAM_DIR/health/<role>.json`;
  README "API rate-limit resilience"), `bin/compaction-watchdog.sh` (early
  compaction; README "Context cost control"), `bin/tmux-watchdog.sh` (crash
  detection, daemon restarts; README "Crash recovery"),
  `bin/permission-mode-watchdog.sh` (holds the launch permission mode; README
  "Safety and unattended running"), `bin/host-ram-watchdog.sh` and
  `bin/disk-tmp-watchdog.sh` (host guards; the latter runs
  `bin/rotate-team-logs.sh`), `bin/chrome-supervisor.sh` (un-wedges a role hung
  on a chrome-devtools MCP call), `bin/observer.sh` (model-backed adviser and
  auditor; recommends, never acts; README "The observer audit").
- `bin/gates/heavy-work-gate.sh [--label X]`: exits 1 while host RAM or disk/tmp
  headroom is in a warn or freeze band; run it before heavy local work.
- From cron: `bin/dreamer.sh` (nightly ledger consolidation, gated on
  `bin/role-activity.sh`) and `bin/night-janitor.sh` (bulk expiry), see
  `docs/dreaming.md`. `bin/capability-probe.sh <probes.conf>` proves the team's
  privileged actions still work (`docs/CAPABILITY-PROBE.md`).
- `bin/hooks/`: the standing-rules hook, tool gates (whole-file reads, `rm` with a
  glob or variable, outbound messages, subagent calls), a Stop hook that keeps a
  role's bus reader armed, and the git `pre-push` privacy scan
  (`docs/ENFORCEMENT.md`).
- `bin/communicator.sh`: opens the `communicator` role, the operator liaison
  (README "The communicator role"). Non-code work: reference roles in `roles/`,
  `verify:` gates in `bin/gates/`, area specialists authored per goal from
  `roles/_TEMPLATE.md` (README "Non-code work").

This is a template, cloned once per project (see [README.md](./README.md) for
the install and run flow), not a shared home for every project's goals. What is
built: [STATUS.md](./STATUS.md); open work: [BACKLOG.md](./BACKLOG.md).

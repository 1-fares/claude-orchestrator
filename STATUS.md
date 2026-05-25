# STATUS

Implementation status of the orchestrator pattern after the design review. The
design is settled; this file tracks what is built. README.md describes the
target design; where the two differ, a stage below is still pending.

## Locked design decisions

Structure (overrides the review's "shrink to one-shot roles" advice, on the
operator's lived experience):

- The `/is` bus stays. The orchestrator may also use agent teams or remote
  agents when a task is a natural fit; that choice is left to the orchestrator.
- Roles are persistent sessions, not one-shot. They are revisited because they
  retain context and the original reasons for decisions.
- The orchestrator picks the team per goal.

Decisions:

1. Shared state: a markdown ledger `.team/state.md` with per-unit sections and a
   running decision-log. Complements orchestrator memory; survives compaction.
2. Verify gate: `bin/verify-unit.sh` (build+test+lint, exit 0). A `done:` is
   accepted only with a fresh green log. Err toward the hard gate; the
   orchestrator may use a soft check for trivial units.
3. Concurrency: git worktree/branch per implementer; a dedicated **integrator**
   role merges (not the orchestrator). The orchestrator decides per goal whether
   to use worktrees or serialize, by judgement (simplicity, shared artifacts).
4. Orchestrator context stays clean: orchestration only, no code/diffs/merging.
5. Containment: a destructive-command deny-list only (`.claude/settings.json`).
   No workdir confinement, no per-role tool scoping.
6. Operator tooling: status command + watch pane, `start-orchestrator.sh`,
   broadcast + a `pause:`/`resume:` convention, per-role log files.
7. Teardown hardening: kill the `/is` bus server (scoped to the team port),
   graceful stop-and-save pass, pid-is-claude sanity check, per-team
   session/port and truncate `.team/active` on launch.
8. Handoff: a structured task brief (`tasks/_TEMPLATE.md`) with fixed fields.
9. Goal input: any form, then a definition-of-ready gate. The orchestrator
   converges the goal into the brief, proposes acceptance criteria, team, and
   autonomy mode, and waits for an explicit "go" before spawning anyone.
10. `/goal` is optional, chosen per role and situation. Three cadence modes:
    interactive (wake on `/is`), `/goal` (exit-0 condition + round budget),
    `/loop` (periodic). A `stop:`/`priority:` message clears an active goal.
11. Orchestrator mode: interactive by default; autonomous (`/goal` to the whole
    feature) is an explicit opt-in.
12. Quality artifacts: tester captures red+green test logs; reviewer produces a
    cited checklist. Default-required; the orchestrator may waive for trivial
    units.
13. Liveness: the orchestrator polls `/is list`, diffs the roster against the
    expected team, flags missing names as dead; roles emit a slow heartbeat.
14. Safety extras: `bin/preflight-deploy.sh` (verify remote+branch+env, human
    token for prod) and `bin/panic.sh` (+ optional watchdog).
15. `bin/check-scope.sh` rejects a diff touching off-limits paths. Rejected,
    partial, or out-of-scope work is never dropped: the orchestrator records the
    remainder as new ledger units.

## Build stages

- **Stage 1 (correctness core)**, done: STATUS, ledger + task-brief templates,
  integrator role, `verify-unit.sh`, `check-scope.sh`, role/prompt edits,
  CLAUDE.md core conventions.
- **Stage 2 (seamlessness)**, done: `team-env.sh` (per-clone bus port + tmux
  session), `start-orchestrator.sh`, `team-status.sh`, `team-watch.sh`,
  `team-broadcast.sh` (out-of-band via tmux send-keys, since external scripts
  cannot get bus auth), `team-logs.sh` (per-role history from the bus
  messages.log; `--sync` materializes `.team/log/<role>.log`), `launch-team.sh`
  (per-team session/port, stale-`.team/active` reap), `stop-team.sh` hardening
  (graceful pass, pid-is-claude guard, bus-server kill scoped to the team port,
  orchestrator window preserved). Worktree helper deferred to Stage 3 with the
  concurrency wiring.
  Note: per-role logs derive from the bus log (the durable store) rather than a
  live pane tee, a TUI pane capture is mostly redraw noise; the bus stream is the
  meaningful, greppable record.
- **Stage 3 (safety + docs)**, done: `.claude/settings.json` (minimal deny-list,
  per the chosen scope; verified that `permissions.deny` is enforced even under
  `--dangerously-skip-permissions`, and that the real force-push pattern blocks),
  `preflight-deploy.sh`, `panic.sh`, `watchdog.sh`, `worktree.sh`; full README
  rewrite; resolved "Open questions" closed (handoff schema, integration
  discipline, shared state, multi-team isolation).
- **B9 (dynamic team scaling)**, done: `bin/add-role.sh` (grow a live team by one
  role, operator-chosen soft cap (default 12, custom, or uncapped), no
  double-spawn, reuse-before-spawn hint,
  decision-log + roster line, ntfy), `bin/retire-role.sh` (graceful single-role
  teardown scoped to one role, refuses on in-flight units unless `--force`
  re-files them as todo, archives health/audit to `retired/`), the shared spawn
  path factored into `bin/lib/team-spawn.sh` (`start_one` reused by launch and
  add) and ledger/roster helpers in `bin/lib/roster.sh`, an idempotent
  api-watchdog start (a repeated launch no longer starts a second watchdog), a
  `## roster` section in the ledger template, and a "Dynamic team management"
  section in the orchestrator role. Safety mirrors `cleanup.sh`: operate only on
  this run's `TEAM_SESSION`, kill only the target role's recorded pid-group +
  window, pid-is-claude guard before any kill, never touch the bus server.

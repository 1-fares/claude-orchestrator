# STATUS

What is built. The design is settled; [README.md](./README.md) describes the
system as it runs today. Open, not-yet-built work is in [BACKLOG.md](./BACKLOG.md).

## Locked design decisions

Structure (overrides the design review's "shrink to one-shot roles" advice, on
the operator's lived experience):

- The `/is` bus stays. The orchestrator may also use agent teams or remote
  agents where a task is a natural fit.
- Roles are persistent sessions, not one-shot: they are revisited because they
  retain context and the original reasons for decisions.
- The orchestrator picks the team per goal.

Mechanics:

1. **Shared state:** a markdown ledger (`$TEAM_DIR/state.md`) with per-unit
   sections, a decision-log, and a roster. Complements orchestrator memory;
   survives compaction.
2. **Verify gate:** `bin/verify-unit.sh` (build + test + lint, exit 0). A `done:`
   is accepted only with a fresh green log. The orchestrator may soft-check
   trivial units.
3. **Scope gate:** `bin/check-scope.sh` rejects a diff touching off-limits paths.
   Rejected, partial, or out-of-scope work is filed as a new ledger unit, never
   dropped.
4. **Concurrency:** git worktree/branch per implementer; a dedicated
   **integrator** merges (not the orchestrator), which keeps the orchestrator's
   context on coordination only. The orchestrator decides per goal whether to use
   worktrees or serialise.
5. **Containment:** a destructive-command deny-list (`.claude/settings.json`)
   only. No workdir confinement, no per-role tool scoping.
6. **Handoff:** a structured task brief (`tasks/_TEMPLATE.md`) with fixed
   `verify:` / `scope:` / `off-limits:` fields that feed the gates.
7. **Goal input:** any form, then a definition-of-ready gate. The orchestrator
   converges the goal, proposes acceptance / team / autonomy mode, and waits for
   an explicit "go".
8. **Cadence:** interactive (wake on `/is`) by default; `/goal` (exit-0 condition
   + round budget) or `/loop` (periodic) per role. A `stop:` / `priority:`
   message clears an active goal. Orchestrator interactive by default; autonomous
   (`/goal` to the whole feature) is an explicit opt-in.
9. **Quality artifacts:** tester captures red + green logs; reviewer produces a
   cited checklist. Default-required; waivable for trivial units.
10. **Deploy safety:** `bin/preflight-deploy.sh` (verify remote + branch + human
    token for prod) and `bin/panic.sh` (+ watchdog).

## Built

**Correctness core.** Ledger + task-brief templates, integrator role,
`verify-unit.sh`, `check-scope.sh`, the CLAUDE.md engineering charter.

**Operator tooling.** `team-env.sh` (per-clone bus port + tmux session, with
optional per-run isolation when `TEAM_RUN_ID` is set), `start-orchestrator.sh`,
`launch-team.sh`, `stop-team.sh` (graceful pass, pid-is-claude guard,
port-scoped bus kill, orchestrator window preserved), `team-status.sh`,
`team-watch.sh`, `team-broadcast.sh` (out-of-band via tmux send-keys),
`team-logs.sh` (per-role history from the durable bus log), `reset.sh`,
`cleanup.sh`, `run.sh` (recovery-aware one-command entry).

**Per-run isolation.** Ledger, task briefs, and role artifacts are per-run under
`$TEAM_DIR`; two `bin/run.sh` invocations in one clone no longer collide. Legacy
single-team mode (no `TEAM_RUN_ID`, state in `.team/`) is unchanged. Covered by
`tests/b9/concurrency-test.sh`.

**Safety.** Minimal deny-list (verified enforced under
`--dangerously-skip-permissions`), `preflight-deploy.sh`, `panic.sh`,
`watchdog.sh`, `worktree.sh`, Claude Code version pin (`team-env.sh`, deliberate
upgrades only).

**Dynamic team scaling (B9).** `add-role.sh` / `retire-role.sh` (grow or shrink a
live team by one role, operator-chosen soft cap, no double-spawn, decision-log +
roster line, ntfy), shared spawn/teardown in `bin/lib/team-spawn.sh` +
`bin/lib/roster.sh`, the `## roster` ledger section. Scoping mirrors `cleanup.sh`
(this run's session only, pid-is-claude guard, never touch the bus server).

**Supervisor daemons.** Pure-shell, no Claude API call, so none can be
rate-limited. Lifecycle: started at launch, re-ensured on every orchestrator
(re)start and role add, self-healed by the tmux-watchdog.
- `api-watchdog.sh`: recovers API rate-limit / network stalls (exponential
  backoff, episode-scoped retry count so repeated same-error stalls reach
  give-up and escalate to the orchestrator instead of looping), usage-limit
  outages (indefinite auto-retry, plus one orchestrator wake nudge when a role
  recovers so the team re-dispatches after an outage), and detects wedged
  roles (busy but no token/pane liveness).
- `tmux-watchdog.sh`: detects tmux-server crash, snapshots panes, self-heals the
  other daemons.
- `compaction-watchdog.sh`: compacts the orchestrator and top-tier roles early at
  idle boundaries; multi-target, probe-blind backstop if `/context` parsing
  breaks; passive ceiling guard on every window, so a worker wedged at the
  terminal "Compaction failed" state is escalated for retire+respawn.
- `chrome-supervisor.sh`: un-wedges roles hung on a chrome MCP call.
- Resource guards: host-RAM OOM watchdog + heavy-work gate, disk/tmp guard.

**Tiered model policy + token economy.** `model_for()` is a judgment-density tier
table (top tier for orchestrator / communicator / reviewers / testers /
fact-checkers / architect / analyst; `opus` for work-producing roles;
`sonnet` / `haiku` mechanical), overridable per role or per tier. Each launch
records its model under `$TEAM_DIR/models/<role>`; the observer and compaction
watchdog read those records. `llm-judge.sh` pins headless judging to `sonnet`.
Rationale: [docs/model-policy.md](./docs/model-policy.md).

**Operator surfaces.** The `communicator` role (two-way operator liaison, TUI +
dashboard chat panel), the read-only visual dashboard (`bin/dashboard.sh`,
force-graph + stats + chat, loopback-only), the B4 remote-control escape-hatch
helpers (`inbox.sh`, `approve.sh`, `team-status.sh --mobile`, the signed
notify-hook).

**Non-code substrate.** A reference role library (`researcher`, `writer`,
`editor`, `fact-checker`, `copy-editor`, `peer-reviewer`, `doc-integrator`, plus
legal references) and the pluggable gate library at `bin/gates/` (`structure`,
`link-live`, `cite-resolve`, `md-lint`, `office-wellformed`, `llm-judge`,
`rubric-judge`, `cite-support`) that a non-code unit's `verify:` line wires.

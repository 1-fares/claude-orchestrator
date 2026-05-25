# claude-orchestrator

A pattern for building software with a team of Claude Code sessions.

One session, the **orchestrator** (where you sit), holds the goal and coordinates
a set of specialised role sessions (analyst, architect, implementer, tester,
reviewer, integrator, devops, deployment). The sessions are independent Claude
Code processes on the same machine; they talk to each other over the
[`/is` message bus](../claude-code-inter-session). The orchestrator decides which
roles a goal needs, launches them, hands out work as structured briefs, and
integrates the results through a dedicated integrator, keeping its own context
for coordination rather than code.

This repository is the pattern: the role prompts, a launcher and operator
tooling, a shared ledger, deterministic gates, an engineering charter, and the
conventions that hold a team together. Clone it per project, point it at a goal,
and it runs. See [STATUS.md](./STATUS.md) for the design decisions behind it.

## Distribution: clone per project

The orchestrator is a template, not a shared home for every goal you run. Clone
it once per target project, so each project's ledger, goals, and any role tweaks
stay separate. Within a clone, `goals/` holds one brief per feature; across
projects, you get a fresh clone. Two ways the clone relates to the code:

- **Greenfield:** build inside the clone (working tree is the clone).
- **Existing codebase:** clone beside the target repo and point the team at it
  with `--workdir`. Roles run in the target tree (and load that project's own
  `CLAUDE.md`); the orchestrator's `CLAUDE.md`, role files, goal, and task briefs
  are read by absolute path.

  ```bash
  bin/start-orchestrator.sh goals/repo-bugfix.md
  # then, from the orchestrator:
  bin/launch-team.sh --workdir ~/projects/some-app goals/repo-bugfix.md implementer1 tester1
  ```

## Why a team

A single long session degrades on large work: context fills with detail from
every layer, and one role's mistake contaminates the rest. Splitting the work
gives each role its own clean context, narrow remit, and history that grows in
value: the implementer keeps the design rationale, the tester keeps the
regression suite, the reviewer keeps the catalogue of edge cases already checked,
the integrator keeps the merge history. You revisit these roles precisely because
they remember the reasons behind decisions.

Claude Code has three concurrency primitives; this pattern uses each where it
fits, and the orchestrator chooses:

| Primitive | What it is | Used for |
| :-- | :-- | :-- |
| **Subagents** (`Agent` tool) | A worker inside one session; result returns, then it exits. | Short fan-out inside a role (search, one-off analysis). |
| **`/is` sessions** | Long-lived independent sessions messaging peer-to-peer over a localhost bus. | The team itself: persistent roles whose accumulating context is the product. |
| **Agent teams** | Built-in lead + teammates with a shared task list, for one task. | A self-contained burst of parallel work the orchestrator hands off whole. |

The bus and persistent roles are the spine, because the roles are long-lived,
cross-project, and resumable. Subagents reset between calls and agent teams exit
when their task ends; neither sustains a multi-round role. For scheduled,
event-driven, or off-machine work the orchestrator can also reach for cloud
[routines](https://code.claude.com/docs/en/routines).

## Roles

The orchestrator is the only required session. Everything else is launched on
demand, in the count the goal needs. Each role has a prompt in [`roles/`](./roles);
the bus name is the file name plus an optional digit, so `implementer1` and
`implementer2` both read `roles/implementer.md`.

| Role | Bus name | Owns |
| :-- | :-- | :-- |
| **Orchestrator** | `orchestrator` | The goal, the ledger, team composition, work assignment, the final call. Delegates code, review, and merging. |
| **Analyst** | `analyst` | Turning a vague goal into testable requirements and acceptance criteria. |
| **Architect** | `architect` | System and interface design, technology choices, breaking work into units. |
| **Implementer** | `implementer<N>` | Writing code for one assigned unit; small, surgical, in its own worktree. |
| **Tester** | `tester<N>` | Tests and adversarial cases; red-before-green capture; reproducing bugs. |
| **Reviewer** | `reviewer<N>` | Independent correctness review; a cited checklist artifact. |
| **Integrator** | `integrator` | Merging units, conflict resolution, the integration build. Keeps merge off the orchestrator. |
| **DevOps** | `devops` | Build, environments, dependencies, tooling, CI. |
| **Deployment** | `deployment` | Release, post-release verification, rollback, deploy preflight. |

Extended roles, added when the goal calls for them: **front-end developer**
(`frontend<N>`, builds the UI), **researcher** (spikes), **security reviewer**
(red-team), **tech writer** (docs).

Keep the team as small as the goal allows. On a local subscription run every
role defaults to the best model (Opus); drop a role to a faster model only for
speed. On API-paid remote agents, invert it: bulk on Sonnet, Opus to check. Tune
`model_for()` in [`bin/lib/team-spawn.sh`](./bin/lib/team-spawn.sh). Current ids: `opus`
(`claude-opus-4-7`), `sonnet` (`claude-sonnet-4-6`), `haiku` (`claude-haiku-4-5`).

## How it works

### The message bus (`/is`)

Coordination runs on the [`/is` skill](../claude-code-inter-session). `/is` is a
**separate sibling project**, maintained and used independently of this
orchestrator, so install it alongside this clone (a sibling directory), not inside
it. It is a fork of
[yilunzhang/claude-code-inter-session](https://github.com/yilunzhang/claude-code-inter-session)
(MIT, original author Yilun Zhang), extended here with file-pointer message
delivery and a short `/is` invocation. Each session joins with a role name, then
messages flow peer-to-peer:

```
/is c orchestrator
/is s implementer1 --file tasks/parser.md      # assign a unit (file pointer)
/is s orchestrator 'status: parser done; verify green'
/is b 'standup: where is everyone?'            # broadcast to all roles
```

A received message is delivered as a prompt and acted on as an instruction by
default, with the caution applied to user input: destructive or ambiguous
requests draw a `question:` first. Reply prefixes (`status:`, `done:`, `answer:`,
`question:`) let the orchestrator route replies. Each clone gets its own bus port
and tmux session (derived in [`bin/team-env.sh`](./bin/team-env.sh)), so several
team clones never collide on the flat namespace.

### The ledger (shared state)

Team state lives in `.team/state.md`, not only in the orchestrator's context.
Copied from [`templates/state.md`](./templates/state.md) at run start, it holds a
per-unit section (owner, status, scope, dependencies, acceptance) and a
decision-log. The orchestrator writes it on every transition and re-reads it
after compaction or a restart, so a long run, or a revisited role, can
reconstruct who owns what and why a choice was made.

### Structured handoffs

Work is assigned as a task brief from [`tasks/_TEMPLATE.md`](./tasks/_TEMPLATE.md),
sent as a file pointer. Its machine-readable header lines feed the gates:

```
unit: parser
verify: make -C build test && make lint
scope: src/parse.c, src/parse.h
off-limits: src/main.c
```

### Cadence: interactive, `/goal`, or `/loop`

A session's cadence is a deliberate choice, not a default. **Interactive** (do a
step, report, yield; the `/is` monitor wakes it on the next message, idle costs
nothing) is the default and fits one-shot roles and any step that should hand
control back. **`/goal`** drives unattended iteration toward a machine-checkable
finish line: phrase the condition as a command that must exit 0
(`/goal bin/verify-unit.sh parser exits 0`), with a round budget, and override it
with a `stop:`/`priority:` message. **`/loop`** runs a periodic action. The
orchestrator runs interactive by default; autonomous mode (orchestrator under
`/goal` to the whole-feature acceptance) is an explicit opt-in for walking away.

### Gates: verify and scope

A completion claim is verified, not trusted. Before a `done:` is accepted:

- [`bin/verify-unit.sh <unit>`](./bin/verify-unit.sh) runs the brief's `verify:`
  command (build, test, lint), logs it, and exit-codes the result.
- [`bin/check-scope.sh <unit>`](./bin/check-scope.sh) rejects a diff that touched
  off-limits or out-of-scope paths.

The tester captures a red-before-green log pair; the reviewer produces a cited
checklist. The orchestrator may waive the gates for trivial units. Rejected,
partial, or out-of-scope work is never dropped: it becomes a new ledger unit.

### A run, end to end

1. You start the orchestrator (`bin/start-orchestrator.sh [goal]`) and state the
   goal in any form.
2. **Definition of ready:** the orchestrator converges the goal into the ledger,
   restates its understanding, the acceptance criteria, the proposed team, and
   the autonomy mode, and waits for your explicit "go".
3. It launches the team, sending analyst/architect first when design is
   unsettled, then implementers and testers as iterating pairs.
4. Implementers work in per-unit worktrees; the integrator merges; the reviewer
   does an independent pass. Gates run before any `done:` is accepted.
5. Deployment releases (after `preflight-deploy.sh`) and verifies live.
6. The orchestrator reports the result, including anything not done, and tears
   the team down (`bin/stop-team.sh`).

## Quickstart

```bash
bin/run.sh                         # the one command: asks the goal (and the
                                   #   target on first run), starts, drops you in
bin/run.sh ~/projects/app          # give the target path up front, then ask the goal
bin/run.sh ~/projects/app "add a --json flag"   # target + goal in one line
bin/run.sh "add a --json flag"     # repeat run, goal inline (uses the saved target)
# watch / intervene / end (from another terminal):
bin/team-status.sh                 # one-glance dashboard
bin/team-broadcast.sh 'pause: hold on'     # intervene out-of-band
bin/reset.sh                       # clean slate for a new run
bin/panic.sh                       # emergency: stop everything
```

`bin/run.sh` is the entry point. The first run in a clone asks which code to work
on (a new path it creates, an existing repo it uses, or blank to build inside the
clone) and remembers it in `project.conf`; later runs only ask for the goal, so a
repeat run against an existing project is one line. It composes the lower-level
scripts (`new-project.sh`, `new-goal.sh`, `start-orchestrator.sh`, `attach.sh`),
which remain available for manual control.

By default the orchestrator and roles share one tmux session (orchestrator =
window 0, roles = windows 1, 2, ...); `bin/run.sh` / `bin/attach.sh` drop you in
and `Ctrl-b <number>` switches between them. The team runs on a dedicated tmux
socket (`-L orchestrator`, no user config), isolated from your default tmux
server and its plugins; tmux-resurrect/continuum on the default server would
otherwise auto-restore the team's windows as stale shells after a teardown.
(Prefer the orchestrator in your own terminal with only roles in tmux?
`start-orchestrator.sh --foreground`.) You only describe the goal; the
orchestrator proposes the acceptance criteria, scope, team, and verify command at
its definition-of-ready gate and confirms before any work starts.

## Launching the team

Each role is a real Claude Code process; something has to start it. From most to
least integrated:

1. **tmux (recommended).** `bin/start-orchestrator.sh` establishes the team's
   tmux session and seeds the orchestrator; the orchestrator then runs
   `bin/launch-team.sh [--workdir DIR] <goal> <role>...` to add a window per role,
   each seeded to join the bus, read its role file and the goal, and report
   ready. Sessions are interactive (not `-p`, which would exit after one
   response) and start with `--dangerously-skip-permissions`. The launchers
   pre-accept Claude Code's workspace-trust prompt for the clone and any external
   `--workdir` (`bin/trust-workdir.sh`, an atomic edit to `~/.claude.json` with a
   `.bak`), since that prompt is only auto-skipped in non-interactive mode and
   would otherwise block a role at startup.
2. **Manual tabs.** Open a terminal per role, `claude --dangerously-skip-permissions`,
   `/is c <role>`, point it at its role file and the goal. The fallback when tmux
   is not in use.
3. **Agent teams** ([built-in, experimental](https://code.claude.com/docs/en/agent-teams)):
   for a self-contained parallel burst the orchestrator hands off whole.
4. **Cloud routines** ([remote](https://code.claude.com/docs/en/routines)):
   scheduled, event-driven, or off-machine work.

## Operating the team

- **Watch:** [`bin/team-status.sh`](./bin/team-status.sh) prints role, pid, alive,
  window, idle time, and last bus message; [`bin/team-watch.sh`](./bin/team-watch.sh)
  runs it on a loop in a pane. The orchestrator additionally runs `/is list` for
  the live bus roster and treats a missing expected role as dead, not slow.
- **Intervene:** [`bin/team-broadcast.sh '<msg>'`](./bin/team-broadcast.sh) types
  an instruction into every role's pane from outside any session (a standalone
  script cannot get bus auth; the orchestrator can use `/is b`). Roles honor a
  `pause:`/`resume:` and `stop:`/`priority:` convention.
- **Logs:** [`bin/team-logs.sh [role]`](./bin/team-logs.sh) shows per-role history
  from the bus message log; `--sync` materializes `.team/log/<role>.log`.

## Concurrency and integration

When the orchestrator runs multiple implementers, it chooses the model by
judgement: separate **git worktrees** for independent units, or **serialize**
when units share artifacts or the work is small. For worktrees,
[`bin/worktree.sh add <unit>`](./bin/worktree.sh) creates a branch and worktree
and prints its path (used as the implementer's `--workdir`); the **integrator**
merges branch `unit/<unit>`, runs the gates at the seam, and resolves or
escalates conflicts. The orchestrator never merges, keeping its context clean.

## Engineering standards

Binding on every role; the tight version is in [`CLAUDE.md`](./CLAUDE.md), loaded
into every session automatically.

- **Verify, do not guess.** Every load-bearing claim traces to a file read, a
  command run, or a test reproduced.
- **Small, surgical changes.** Touch only the assigned unit; no drive-by edits.
- **Test with real tools.** Run the suite; drive a real browser via the
  chrome-devtools MCP; compare bytes for binary output. Done means seen to work.
- **No silent partial work.** Finish, or report the blocker and what is left.
- **Scripts over judgement.** Deterministic, rule-based work (spawn, teardown,
  validation, gates, status, scaffolding) is a script, not an LLM turn. The
  mechanical parts of this pattern are scripts under [`bin/`](./bin); reserve LLM
  cycles for design, code, debugging, and review.

## Safety and unattended running

Sessions run with `--dangerously-skip-permissions` so no role stops on a prompt.
That is safe only in a trusted local environment.

- **Deny-list.** [`.claude/settings.json`](./.claude/settings.json) denies a
  minimal set of irreversible commands (force-push, history rewrite, remote
  branch deletion, catastrophic deletes). Deny rules are enforced even under
  bypass (verified), but argument-matching patterns are best-effort, not airtight;
  the deny-list is a tripwire against accidental and obvious destructive commands,
  not a guarantee against a determined or injected adversary.
- **Deploy preflight.** [`bin/preflight-deploy.sh`](./bin/preflight-deploy.sh)
  verifies remote, branch, and (for prod) a human-set `ORCHESTRATOR_DEPLOY_OK=1`
  token before any release. Deployment refuses on a mismatch.
- **Kill-switch and watchdog.** [`bin/panic.sh`](./bin/panic.sh) stops everything
  including the orchestrator; [`bin/watchdog.sh`](./bin/watchdog.sh) enforces a
  wall-clock and message-volume ceiling on an autonomous run.
- **Rate limits.** Claude Code retries transient failures (429/529/timeouts) with
  backoff. For long runs, `CLAUDE_CODE_MAX_RETRIES=40` and `API_TIMEOUT_MS=900000`
  harden it; stagger starts (the launcher sleeps 1s between roles) and reduce
  concurrency or model size on sustained limits.
- **Cost.** Right-size the team, tier models by where work runs (above), let idle
  roles idle (a waiting `/is` session costs nothing), and offload schedulable work
  to cloud routines.

## Project layout

```
claude-orchestrator/
├── README.md  CLAUDE.md  STATUS.md
├── .claude/settings.json     # deny-list
├── roles/                    # one prompt per role (incl. integrator)
├── goals/                    # per-feature briefs (_TEMPLATE.md)
├── tasks/                    # per-unit task briefs (_TEMPLATE.md)
├── templates/state.md        # ledger format -> .team/state.md
├── bin/
│   ├── team-env.sh           # per-clone bus port + tmux session (sourced)
│   ├── lib/                   # sourced helpers: team-spawn.sh, roster.sh
│   ├── start-orchestrator.sh launch-team.sh stop-team.sh panic.sh
│   ├── add-role.sh retire-role.sh   # dynamic team scaling (grow/shrink mid-run)
│   ├── new-goal.sh worktree.sh
│   ├── verify-unit.sh check-scope.sh preflight-deploy.sh
│   └── team-status.sh team-watch.sh team-broadcast.sh team-logs.sh watchdog.sh
└── .team/                    # transient: ledger, prompts, active record, logs
```

## Open questions and future work

Resolved since the design review: handoff format (structured task briefs),
integration discipline (worktrees plus a dedicated integrator), shared state (the
ledger), multi-team isolation (per-clone bus port and tmux session). Remaining:

- **Team composition heuristics.** When two implementers earn their cost over
  one, when a separate reviewer earns its cost over the tester. Wants real runs.
- **`/is` across machines.** The bus is localhost-only. TCP would let a team span
  hosts (a build box, a separate test runner).
- **`/is` native namespacing.** Per-clone ports isolate teams today; a team id or
  logical channel within one bus would be cleaner and pairs with the cross-machine
  work, and would need real authentication once it crosses a trust boundary.
- **Containment depth.** The deny-list is a tripwire; airtight containment would
  add a workdir-confinement hook or OS sandbox.

## See also

- [`../claude-code-inter-session`](../claude-code-inter-session): the `/is` bus, a
  separate sibling project (install alongside this clone, not bundled). Fork of
  [yilunzhang/claude-code-inter-session](https://github.com/yilunzhang/claude-code-inter-session)
  (MIT, original author Yilun Zhang).
- [agent teams](https://code.claude.com/docs/en/agent-teams),
  [routines](https://code.claude.com/docs/en/routines),
  [`/goal`](https://code.claude.com/docs/en/goal),
  [`/loop`](https://code.claude.com/docs/en/scheduled-tasks),
  [permissions](https://code.claude.com/docs/en/permissions): the Claude Code
  features this pattern composes.

# claude-orchestrator

A pattern for building software with a team of Claude Code sessions.

One session, the **orchestrator** (where you sit), holds the goal and
coordinates a set of specialised role sessions: analyst, architect, implementer,
tester, reviewer, integrator, devops, deployment. The sessions are independent
Claude Code processes on the same machine; they talk to each other over the
[`/is` message bus](https://github.com/1-fares/claude-code-inter-session). The
orchestrator decides which roles a goal needs, launches them, hands out work as
structured briefs, gates "done" with verify and scope checks, and integrates the
results through a dedicated integrator, keeping its own context for coordination
rather than code.

This repository is the pattern: role prompts, a launcher and operator tooling, a
shared ledger, deterministic gates, an engineering charter, and the conventions
that hold a team together. It is a template. Clone it once per target project,
point it at a goal, and it runs.

## Prerequisites

- `tmux` (any modern version).
- `claude` (the Claude Code CLI; v2.1.110+ recommended for `/remote-control` push).
- `python3` and `uv` (for the `/is` skill and a few helpers).
- The [**`/is`** (inter-session) skill](https://github.com/1-fares/claude-code-inter-session)
  installed as a sibling project. The orchestrator depends on fork-specific
  features (`/is` short command, `--file` message pointers); install the fork at
  `1-fares/claude-code-inter-session`, not the upstream original. Credit:
  original by Yilun Zhang ([`yilunzhang/claude-code-inter-session`](https://github.com/yilunzhang/claude-code-inter-session),
  MIT).
- Linux / macOS / WSL2. The bus is localhost-only and Unix-only.

## Install

```bash
mkdir -p ~/projects && cd ~/projects

# 1. The /is bus (sibling project, installed as a Claude Code skill).
git clone https://github.com/1-fares/claude-code-inter-session.git
cd claude-code-inter-session
# Follow that repo's README to register the skill with Claude Code.
# When done, /is is available as a slash command in any Claude Code session.
cd ..

# 2. This orchestrator (a template; one clone per target project is the norm).
git clone https://github.com/1-fares/claude-orchestrator.git
cd claude-orchestrator
```

That is the full install. The two repos live as siblings; the orchestrator does
not read the sibling clone. It uses the skill where Claude Code installs it,
`~/.claude/skills/is/bin` (`bin/bus-inbox.py`, `bin/bus-send.py`,
`bin/launch-team.sh`; `IS_BIN` overrides the path for `bin/bus-inbox.py`).

## Run a goal

```bash
bin/run.sh
```

`bin/run.sh` allocates a fresh `TEAM_RUN_ID`, spawns the orchestrator into a
dedicated tmux session, and attaches you. You land in the orchestrator (window
0). The orchestrator then asks you, in the session (visible, recorded,
recoverable), not through shell prompts:

1. **Working tree.** A new path to create, an existing repo to work on, or this
   clone (greenfield).
2. **What to build or change.** Free text: a sentence, a paragraph, a pasted
   issue.
3. **Optional constraints, mode (interactive / autonomous), team-size cap.**

`bin/start-orchestrator.sh` has already seeded `.team-<run-id>/state.md` from
`templates/state.md` (`cp -n`, so an existing ledger is never overwritten). The
orchestrator echoes your brief back, writes the goal file, fills the ledger,
breaks the work into units, and presents a **READY** summary. Reply `go` to start, or any adjustment
(different acceptance, different team, different verify command) followed by
`go`.

Power path, skipping the in-session prompts:

```bash
bin/run.sh ~/projects/app                       # set target, ask the goal
bin/run.sh ~/projects/app "add a --json flag"   # set target + goal in one line
bin/run.sh "add a --json flag"                  # repeat run; reuses saved target
bin/run.sh --retarget                           # forget the saved target
```

The orchestrator runs interactive by default. Switch to autonomous (the
orchestrator under `/goal` to the whole-feature acceptance) only when you want
to walk away and the acceptance is a single exit-0 command.

`bin/run.sh` composes the lower-level scripts, which also work on their own:

- `bin/new-project.sh <dir>`: scaffold a brand-new target repo (git, one initial
  commit, as `check-scope.sh` and worktrees need).
- `bin/new-goal.sh`: a short questionnaire that writes a goal brief; you describe
  the goal, the orchestrator fills in acceptance, scope, team and verify at the
  READY gate.
- `bin/start-orchestrator.sh [--foreground] [goal-file]`: the first run and the
  recovery entry point. By default the orchestrator and the roles share ONE tmux
  session; `--foreground` runs the orchestrator in your terminal instead, with
  the roles still in tmux. Every (re)start ensures the supervisor daemons (see
  [Daemon lifecycle](#daemon-lifecycle)), so a recovery does not leave them dead.
- `bin/launch-team.sh`: spawn the roles (`--workdir` to target external code).
- `bin/attach.sh`: attach to the team tmux session.

## Drive the team

By default the orchestrator and all roles share one tmux session, orchestrator =
window 0, roles = windows 1, 2, ...

```
INSIDE TMUX
  prefix <N>     switch to window N        prefix w     window list
  prefix n / p   next / prev window        prefix d     detach (SAFE)

MONITOR (from any terminal)
  bin/team-status.sh               one-glance status view
  bin/team-watch.sh                live status view
  bin/team-logs.sh [<role>]        per-role message history (durable)

CONTROL
  bin/team-broadcast.sh "<msg>"    inject to every role from outside the bus
  bin/stop-team.sh                 end roles, keep orchestrator
  bin/reset.sh                     end everything + clear this run's state
  bin/cleanup.sh                   dry-run; detects orphans + misfires
  bin/cleanup.sh --force --purge   apply (scoped to this clone's team only)
  bin/panic.sh                     emergency stop (last resort)
```

`bin/cleanup.sh` recovers from a misfire: it reaps orphaned role sessions the
other scripts miss (a lost tmux session, a launch with no `$TEAM_DIR/active`),
is a dry-run by default, applies with `--force`, and with `--purge` also removes
config and artifacts. `/is` sessions not attributable to this clone are
reported, never killed.

The team runs on a dedicated tmux socket (`-L orchestrator`, no user config), so
it is isolated from your default tmux server and any plugins
(tmux-resurrect/continuum on the default server would otherwise try to restore
the team's windows as stale shells after teardown). Use `bin/attach.sh` and
`bin/team-status.sh`, not a plain `tmux attach`.

**Do not end the orchestrator with `Ctrl-d`.** That exits the orchestrator
process but leaves role sessions running as orphans (the `claude` CLI survives
the parent shell exit). Use `prefix d` to detach (the team keeps running),
`bin/stop-team.sh` to end the roles, or `bin/reset.sh` to end everything and
clear state.

## Parallel runs in one clone

Every `bin/run.sh` invocation gets its own `TEAM_RUN_ID`, and therefore its own
bus port, tmux session, and state directory (`.team-<run-id>/`); the scripts and
roles it spawns inherit the id, and [`bin/team-env.sh`](./bin/team-env.sh)
derives the rest from it. Two teams in one clone never share state or collide on
names. Without `TEAM_RUN_ID` (legacy single-team mode) the port and session are
per clone and the state is in `.team/` (ledger `.team/state.md`). To address a
specific run from outside:

```bash
TEAM_RUN_ID=<id> bin/attach.sh       # attach a specific parallel run
TEAM_RUN_ID=<id> bin/team-status.sh  # status for that run
bin/inbox.sh                         # every parallel run on this clone, with attach hints
```

`bin/run.sh` is recovery-aware: on start it detects any live runs on the team
socket and offers to attach an existing one or start a new parallel run.

## Roles

The orchestrator is the only required session. Everything else is launched on
demand, in the count the goal needs. Each role has a prompt in
[`roles/`](./roles); the bus name is the file name plus an optional digit, so
`implementer1` and `implementer2` both read `roles/implementer.md`.

| Role | Bus name | Owns |
| :-- | :-- | :-- |
| **Orchestrator** | `orchestrator` | The goal, the ledger, team composition, work assignment, the final call. Delegates code, review, and merging. |
| **Communicator** | `communicator` | Two-way liaison with the operator (TUI). Curated, not auto-generated. |
| **Analyst** | `analyst` | Turning a vague goal into testable requirements and acceptance criteria. |
| **Architect** | `architect` | System and interface design, technology choices, breaking work into units. |
| **Implementer** | `implementer<N>` | Writing code for one assigned unit, small and surgical, in its own worktree. |
| **Tester** | `tester<N>` | Tests and adversarial cases; red-before-green capture; reproducing bugs. |
| **Reviewer** | `reviewer<N>` | Independent correctness review; a cited checklist artifact. |
| **Integrator** | `integrator` | Merging units, conflict resolution, integration build. Keeps merge off the orchestrator. |
| **DevOps** | `devops` | Build, environments, dependencies, tooling, CI. |
| **Deployment** | `deployment` | Release, post-release verification, rollback, deploy preflight. |

Further role files in [`roles/`](./roles), added when the goal calls for them:
`frontend` and `backend` (`frontend<N>`, `backend<N>`), `android`,
`ux-designer`, `graphic-designer`, and `user-communicator` (the communicator's
spec, which `bin/communicator.sh` reads).

**Roles are open-ended.** If a goal needs a role with no `roles/<base>.md` (a
security reviewer, a tech writer, a market analyst), the orchestrator
authors one before launch from [`roles/_TEMPLATE.md`](./roles/_TEMPLATE.md),
tailored to that role and the goal. Curated non-code references are already in
[`roles/`](./roles): `researcher`, `writer`, `editor`, `fact-checker`,
`copy-editor`, `peer-reviewer`, `doc-integrator`, plus three cross-cutting legal
references (`paralegal`, `lawyer`, `swiss-law-specialist`). Area specialists
(e.g. `employment-lawyer1`, `tenancy-lawyer1`, `market-analyst1`) are not
predefined; they are authored on the fly so the operator can pursue any topic
without growing the curated set.

Keep the team as small as the goal allows. Models are assigned per role by a
tiered policy in `model_for()`
([`bin/lib/team-spawn.sh`](./bin/lib/team-spawn.sh)), keyed on judgment
density: judgment-dense roles whose mistakes bound the whole run
(orchestrator, communicator, reviewers, testers, fact-checkers,
architect/analyst) default to the top tier (`fable`); work-producing roles
(implementers, writers, researchers, integrator, ...) ride `opus`; mechanical
roles get `sonnet` or `haiku`. Override per role with `TEAM_MODEL_<ROLE>`
(e.g. `TEAM_MODEL_REVIEWER2=opus`), or move whole tiers with
`TEAM_MODEL_TOP` / `TEAM_MODEL_DEFAULT` (no top-tier access:
`TEAM_MODEL_TOP=opus`; cost-capped run: `TEAM_MODEL_DEFAULT=sonnet`). The
aliases are passed straight to `claude --model`, so there are no version
strings to maintain here. Headless calls (gates, observer) are pinned to
cheap models independently. Each launch records the role's model in
`$TEAM_DIR/models/<role>`; the observer and the compaction watchdog read those
records. Rationale, cost model, and the token-economy disciplines (sub-agent
bulk reads, file pointers, early compaction) that keep the top tier affordable:
[`docs/model-policy.md`](./docs/model-policy.md).

## How it works

### The message bus (`/is`)

Coordination runs on the
[`/is` skill](https://github.com/1-fares/claude-code-inter-session), a separate
sibling project (install once, used by any number of orchestrator clones). Each
session joins with a role name, then messages flow peer-to-peer:

```
/is c orchestrator
/is s implementer1 --file $TEAM_DIR/tasks/parser.md  # assign a unit (file pointer)
/is s orchestrator 'status: parser done; verify green'
/is b 'standup: where is everyone?'                # broadcast to all roles
```

A team role does not keep a `/is c` Monitor armed: it runs one long-lived
listener and a blocking reader ([`bin/bus-inbox.py`](./bin/bus-inbox.py), loop in
[`docs/BUS-INBOX.md`](./docs/BUS-INBOX.md)), so an idle role wakes only for a
message, a 2-hour heartbeat or a dead listener, and never leaves the bus to re-arm.

A received message is delivered as a prompt and acted on as an instruction by
default, with the caution applied to user input: destructive or ambiguous
requests draw a `question:` first. Reply prefixes (`status:`, `done:`,
`answer:`, `question:`) let the orchestrator route replies. Each clone gets its
own bus port and tmux session (derived in
[`bin/team-env.sh`](./bin/team-env.sh)), so several teams in one clone or
several clones on one machine never collide on the flat bus namespace.

### The ledger (shared state)

Team state lives in `$TEAM_DIR/state.md`, not only in the orchestrator's
context. Copied from [`templates/state.md`](./templates/state.md) at run start,
it holds a per-unit section (owner, status, scope, dependencies, acceptance),
a decision-log, and a roster of add/retire events. The orchestrator writes it
on every transition and re-reads it after compaction or restart, so a long run
or a revisited role can reconstruct who owns what and why a choice was made.

### Structured handoffs

Work is assigned as a task brief from [`tasks/_TEMPLATE.md`](./tasks/_TEMPLATE.md),
sent as a file pointer. Its machine-readable header lines feed the gates:

```
unit: parser
verify: make -C build test && make lint
scope: src/parse.c, src/parse.h
off-limits: src/main.c
```

Briefs are written under `$TEAM_DIR/tasks/<unit>.md`, so two parallel runs in
one clone never overwrite each other's identically-named brief. The gates read
there first, then fall back to `$ORCH_HOME/tasks/`.

### Cadence: interactive, `/goal`, or `/loop`

A session's cadence is a deliberate choice, not a default. **Interactive** (do a
step, report, yield; the bus reader wakes it on the next message, idle costs
nothing) is the default and fits one-shot roles and any step that should hand
control back. **`/goal`** drives unattended iteration toward a machine-checkable
finish line: phrase the condition as a command that must exit 0
(`/goal bin/verify-unit.sh parser exits 0`), with a round budget, and override
it with a `stop:` or `priority:` message. **`/loop`** runs a periodic action.
The orchestrator runs interactive by default; autonomous (orchestrator under
`/goal` to the whole-feature acceptance) is an explicit opt-in for walking away.

### Gates: verify and scope

A completion claim is verified, not trusted. Before a `done:` is accepted:

- [`bin/verify-unit.sh <unit>`](./bin/verify-unit.sh) runs the brief's `verify:`
  command (build, test, lint), logs it, and exit-codes the result.
- [`bin/check-scope.sh <unit>`](./bin/check-scope.sh) rejects a diff that
  touched off-limits or out-of-scope paths.

When several units share one working tree, `check-scope.sh` checks only the
changes attributed to the unit: commits whose message ends with a `Unit: <unit>`
trailer or that are listed in `$TEAM_DIR/commits/<unit>`, and uncommitted paths
claimed in `$TEAM_DIR/claims/<unit>`. When no commit in the range carries a
trailer and no list exists, every commit since the unit's baseline
(`$TEAM_DIR/base/<unit>`, written by `bin/unit-start.sh`) is charged to it.
Detail in the script header.

**The toolbox.** [`bin/tools/`](./bin/tools) holds small coding helpers a role
runs as `$ORCH_HOME/bin/tools/<name>` instead of re-deriving boilerplate:
`probe-env.sh` (detect a repo's build/test/lint and a `verify:` line),
`impact-scan.sh` (reverse-dependency scan before editing a file), `red-green.sh`
(capture the tester's fail-then-pass evidence pair), `diff-summary.sh` (compact
change summary for review). Prefer them over hand-rolling the same boilerplate;
grow the set from the retro loop, not a brainstorm
([`bin/tools/README.md`](./bin/tools/README.md)).

The tester captures a red-before-green log pair; the reviewer produces a cited
checklist. The orchestrator may waive the gates for trivial units. Rejected,
partial, or out-of-scope work is never dropped: it becomes a new ledger unit.

A pluggable **gate library** at [`bin/gates/`](./bin/gates) covers non-code
units (`structure`, `link-live`, `cite-resolve`, `md-lint`, `office-wellformed`,
`llm-judge`, `rubric-judge`, `cite-support`). A goal's `tasks/<unit>.md`
`verify:` line wires one of these.

[`bin/gates/heavy-work-gate.sh [--label X]`](./bin/gates/heavy-work-gate.sh)
takes no artifact: it exits 1 while host RAM or disk/tmp headroom is in the warn
or freeze band (read live, and from the markers of the host-RAM and disk/tmp
watchdogs). Nothing calls it automatically; it is available for a role or a
brief's `verify:` line to run before heavy local work, for example
`bin/gates/heavy-work-gate.sh --label "full suite" && npm test`.

### A run, end to end

1. You start the orchestrator (`bin/run.sh`) and state the goal in any form.
2. **Definition of ready.** The orchestrator converges the goal into the ledger,
   restates its understanding, the acceptance criteria, the proposed team, and
   the autonomy mode, and waits for your explicit `go`.
3. It launches the team, sending analyst and architect first when design is
   unsettled, then implementers and testers as iterating pairs.
4. Implementers work in per-unit worktrees; the integrator merges; the reviewer
   does an independent pass. Gates run before any `done:` is accepted.
5. Deployment releases (after `preflight-deploy.sh`) and verifies live.
6. The orchestrator reports the result, including anything not done, and tears
   the team down (`bin/stop-team.sh`).

## Concurrency, integration, dynamic scaling

### Worktrees and the integrator

When the orchestrator runs multiple implementers, it chooses the model by
judgement: separate **git worktrees** for independent units, or **serialise**
when units share artifacts or the work is small. For worktrees,
[`bin/worktree.sh add <unit>`](./bin/worktree.sh) creates a branch and worktree
and prints its path (used as the implementer's `--workdir`); the integrator
merges branch `unit/<unit>`, runs the gates at the seam, and resolves or
escalates conflicts. The orchestrator never merges, which keeps its context
clean. `bin/worktree.sh remove <unit>` refuses a worktree git will not remove
(uncommitted or untracked changes, a lock) and prints git's reason; `--force`
removes it anyway and discards those changes. The branch is kept.

### Dynamic team scaling

The team is not frozen at the READY gate. Mid-run the orchestrator can grow or
shrink the roster:

- `bin/add-role.sh [--workdir DIR] <goal> <role> --reason "<why>" [--task <brief>]` spawns one
  role into the live session, enforces a soft cap (default 12, custom, or
  uncapped, set at start in `$TEAM_DIR/max-team-size`; `MAX_TEAM_SIZE` in the
  environment overrides it for one call), refuses double-spawn, warns on
  reuse-before-spawn, writes a decision-log + roster line, and files an
  operator notice of class `info` (the daily digest, no phone push; `--no-ntfy`
  skips it).
- `bin/retire-role.sh <role> [--reason "<why>"]` does a graceful single-role
  teardown scoped to that role only. It refuses if the role owns in-progress
  units; `--force` re-files them as `todo` first. Health and audit are archived
  to `$TEAM_DIR/retired/<role>/`, and the same `info` notice is filed.

Both reuse the shared single-role spawn and teardown code in `bin/lib/`
(`team-spawn.sh`, `roster.sh`) and the same safety scoping as `cleanup.sh`:
this run's session only, a pid-is-claude guard, the bus server never touched.

**Pause vs retire** is a deliberate distinction. An idle role on the bus costs
nothing (its bus reader blocks with no API calls until a message or the
two-hour heartbeat). So retire is not a
cost lever; its value is freeing a slot under the cap and keeping the roster
legible. Temporarily-idle role: send `pause:` over the bus (free, instant
resume, keeps context). Done for good: retire (terminal, frees the slot, loses
context).

## Default to act

Standing principle for every role: **idle time waiting on the operator is a
defect, not a courtesy.** A team of eight roles sitting still for hours because
someone asked the operator to choose between "fix 3 inline" and "fix all 6
inline" is worse than picking either option and continuing. The wrong choice
costs one round of follow-up; the unasked choice costs the team's entire wall
clock.

Roles decide locally and act on anything tactical inside an already-agreed
brief. The orchestrator escalates to the operator only when one of the
following is true:

- Strategic scope change (new round, dropped feature, team rethink).
- Destructive or expensive ops (force-push to a protected branch, prod deploy,
  mass deletion, large batched generation).
- Novel creative direction the operator has not steered.
- Security or auth surface change.
- Hard blocker the team genuinely cannot resolve.
- Internally contradictory brief.

When unclear, the default is **act**. Detailed rationale and the ask pattern
("I'm doing X, rationale: ..., saying so unless you object") are in
[`docs/default-to-act.md`](./docs/default-to-act.md).

## Operator surfaces

### The communicator role

The `communicator` is the team's continuous, two-way liaison with the operator.
One bus identity per run, multiple front-ends share it through disk-persisted
conversation state under `$TEAM_DIR/comm/`. It does not author code or own the
goal; it carries traffic, handles narrow tactical questions itself, and routes
the rest to the orchestrator. Spec: [`roles/user-communicator.md`](./roles/user-communicator.md).

The front-end is `bin/communicator.sh`, which opens a Claude Code session in
the `communicator` role in a new tmux window (or `--foreground` to run in the
current terminal). Idempotent: a second invocation reattaches.

There is no browser front-end: the B11 visual dashboard was removed on
2026-10-19 (reasons in [STATUS.md](./STATUS.md)); `bin/team-status.sh` and
`bin/team-watch.sh` cover the observability it provided.

### Remote control from a phone

Primary: **Claude Code Remote Control** (`/remote-control`, alias `/rc`).
First-party, outbound-only, scan the QR with the Claude mobile app, and the
conversation syncs to the phone with push notifications when Claude needs input.
This covers the 95% case: reading orchestrator output, answering clarifying
questions, typing replies at READY gates. It does not cover role-window
scrollback or arbitrary shell commands on the host.

Escape hatch for when `/remote-control` is not enough (a tester's scrollback, a
manual cleanup, switching between parallel runs):

- `bin/team-status.sh --mobile`: ~40-column compact status view.
- `bin/inbox.sh`: every parallel run on this clone with attach + approve
  commands.
- `bin/approve.sh [<text>]`: send `<text>` (default `go`) to a specific run's
  orchestrator pane (`TEAM_RUN_ID=<id> bin/approve.sh`).

These helpers run on the host. Reaching a shell on the host from the phone
(Tailscale, Cloudflare Tunnel, anything else) is a separate problem and is not
covered here. Operator notices from the daemons arrive in the ntfy app (see
[Operator paging](#operator-paging-what-reaches-the-phone)); they carry no
buttons.

## Safety and unattended running

Sessions run with `--dangerously-skip-permissions` so no role stops on a
prompt. That is safe only in a trusted local environment.

- **Deny-list.** [`.claude/settings.json`](./.claude/settings.json) denies a
  minimal set of irreversible commands (force-push, history rewrite, remote
  branch deletion, catastrophic deletes). Deny rules are enforced even under
  bypass (verified), but argument-matching patterns are best-effort, not
  airtight; the deny-list is a tripwire against accidental and obvious
  destructive commands, not a guarantee against a determined or injected
  adversary.
- **Deploy preflight.** [`bin/preflight-deploy.sh`](./bin/preflight-deploy.sh)
  verifies remote, branch, and (for prod) a human-set `ORCHESTRATOR_DEPLOY_OK=1`
  token before any release. Deployment refuses on a mismatch.
- **Kill-switch and watchdog.** [`bin/panic.sh`](./bin/panic.sh) stops
  everything including the orchestrator;
  [`bin/watchdog.sh`](./bin/watchdog.sh) enforces a wall-clock and message-
  volume ceiling on an autonomous run.
- **Permission-mode watchdog.**
  [`bin/permission-mode-watchdog.sh`](./bin/permission-mode-watchdog.sh) holds
  every pane in the permission mode the run was launched with (default
  `bypass permissions`). Drift off that mode is silent, sticky and one stray
  shift+tab away in the pane humans type into; it turns routine commands into
  confirmation menus nobody can answer remotely (2026-08-25: a `gh pr merge`
  parked an orchestrator six times in one afternoon, about 158 minutes in
  total). It restores the mode and cancels the auto-mode classifier gate with
  Escape. It never confirms a prompt, never presses keys into an open menu, and
  never cycles a mode it cannot read; a pane whose mode stays unreadable for
  `PMW_UNREADABLE_ALARM` sweeps (default 10) gets a marker and an operator
  notice of class `action`. Disable with `PERMISSION_MODE_WATCHDOG_DISABLED=1`.
- **Privacy scan.** This repository is public: `git diff --cached | bash
  bin/privacy-scan.sh` before a commit, and the `bin/hooks/pre-push` hook scans
  the content and the author and committer identity of every outgoing commit,
  installed once per clone either as a symlink
  (`ln -sfn ../../bin/hooks/pre-push .git/hooks/pre-push`) or with
  `git config core.hooksPath bin/hooks`, which disables every other hook in
  `.git/hooks` ([`docs/ENFORCEMENT.md`](./docs/ENFORCEMENT.md)).

### API rate-limit resilience (api-watchdog)

Transient Anthropic API rate-limit or network errors stall a role's pane with a
`try again` prompt; in a multi-role run, an unwatched stall halts the team
silently. [`bin/api-watchdog.sh`](./bin/api-watchdog.sh) is a supervisor daemon
whose lifecycle is described in [Daemon lifecycle](#daemon-lifecycle) below. It
is started at launch, re-ensured on every orchestrator (re)start and role add,
and self-healed by the tmux-watchdog, so it can never be silently absent while a
team runs. It is a pure-shell daemon that scans every team window,
detects the stall, and sends `try again` with exponential backoff
(30s → 60s → 120s → 300s → 600s, max 5 retries; `API_BACKOFF_SEC` overrides).
The retry count is **episode-scoped**: each retry makes the pane busy for a
scan or two, which resets the per-scan counters, so without a memory a role
stalling on the *same* error (classically a content-filter block on quoted
source text) retried forever and never escalated. Stalls separated by less
than `API_EPISODE_WINDOW_SEC` (default 1800s) are one episode whose count and
backoff pacing persist in a marker file; after max retries in one episode the
watchdog gives up **and hands the error to the orchestrator** (which owns the
recovery ladder: split the unit, delegate the blocked passage to a sub-agent,
or retire+respawn the owner), once per episode. The give-up also files an
operator notice of class `action`. Stalls, retries and recoveries are logged,
never pushed.

Per-role state lives in `$TEAM_DIR/health/<role>.json` (one `state` field:
`active`, `stalled-api`, `stalled-usage`, `give-up`, `stuck`, `stuck-giveup`,
`stuck-giveup-esc`, `awaiting-input`, `awaiting-input-esc`) and is visible in
the `HEALTH` column of `bin/team-status.sh`. Awareness is pull-only: the
orchestrator reads `$TEAM_DIR/health/` to decide. The watchdog makes no Claude
API call so it cannot itself be rate-limited. Patterns live in
`bin/api-watchdog.patterns`; the pure pane detectors in
`bin/lib/watchdog-detect.sh` (unit-tested by `bin/tests/watchdog-detect-test.sh`;
end-to-end recovery by `bin/tests/watchdog-stuck-integration-test.sh`). Disable
the whole watchdog with `API_WATCHDOG_DISABLED=1`; every other variable is
listed in the script header.

**Stuck (wedged) roles.** A role that is busy (spinner up) but shows no liveness
for `STUCK_THRESHOLD_SEC` (default 480s) is hung on a tool call, classically a
chrome-devtools MCP call after the debug Chrome dies. A stall detector alone
cannot see this: a spinner reads as healthy, so a wedge silently stalls the run.
Liveness = the pane content changed OR the streaming token counter advanced; the
token counter climbs during a long legitimate think (so a think is not mistaken
for a wedge) but freezes on a hung call, and the elapsed timer is ignored (it
ticks even when wedged). Before acting, the watchdog also reads the session's
transcript: a turn that has ended vetoes the stuck reading, and a subagent
transcript still being written counts as liveness. Recovery ladder: first an
Escape plus a nudge to the role's own pane (gentle, autonomous, keeps context);
after `STUCK_MAX_NUDGES` (default 2) failed attempts the role is marked
`stuck-giveup` and the orchestrator is asked to retire and respawn it. Only a
worker still frozen `STUCK_OPERATOR_SEC` later (`stuck-giveup-esc`), or a wedged
orchestrator (the watchdog writes `PENDING.md`), pages the operator. Disable
stuck detection alone with `STUCK_WATCHDOG_DISABLED=1`.

**Blocked on a prompt.** A role waiting on an interactive prompt (a selection
menu, an `Enter to confirm` footer that is not the usage dialog) classifies
`awaiting-input`. The watchdog never answers it. After `AWAIT_OPERATOR_SEC`
(default 300s) it writes `$TEAM_DIR/health/awaiting-<role>.md`, tells the
orchestrator over the bus first (it can often answer or re-route without a
human; never told about itself), then files an operator notice of class
`action`, and repeats both at the widening gaps of `AWAIT_ESC_STEPS` (default
1200s, then every 3600s) while the prompt stays open (`awaiting-input-esc`).

**Downloading issue/PR attachments.** A plain unauthenticated fetch of a GitHub
`user-attachments` URL returns 404, which is easily misread as "attachments need
a browser login the team does not have." They do not.
[`bin/gh-attachments.sh`](./bin/gh-attachments.sh) `<issue-or-pr-url>` (or
`<owner>/<repo> <num>`) pulls the body and all comments via the `full+json` media
type, extracts every attachment, and downloads each into a per-ticket dir under
`${GH_ATTACHMENTS_DIR:-$HOME/scratch/gh-attachments}` (it refuses a directory
inside a git repository): images and videos via the short-lived signed `jwt` URLs GitHub rewrites them to (no auth
header), plain files via the `gh` token. It self-diagnoses the one credential
gotcha: GitHub does not honor a **fine-grained** PAT for `user-attachments`
downloads, so file attachments need a classic PAT or an oauth `gh auth login`
(images/videos still work regardless). This lets a role get full bug context from
a ticket's screenshots instead of asking the reporter to re-send them.

**Reaching the operator: pings are logged or they did not happen.** When a role
needs the operator's attention on their phone (a gated decision, an incident),
the one sanctioned path is [`bin/notify-operator.sh`](./bin/notify-operator.sh)
`TITLE MESSAGE [page|action|info]` (policy under [Operator paging](#operator-paging-what-reaches-the-phone)):
every decision is one line in `$TEAM_DIR/reports/operator-pings.log`, the script
prints whether the phone got the notice, and it exits non-zero when the notice
was demoted or not delivered, so "I pinged the operator" is a checkable claim,
not an assertion. The harness PushNotification tool is not a
substitute (it reaches the terminal/desktop session, not a phone) and a
production run lost an operator-gated decision for hours to exactly that
confusion (2026-07-21).

A usage/credit outage is a distinct failure mode: Claude Code parks the
session on a modal dialog ("Stop and wait for limit to reset / Add funds /
Enter to confirm") that shows no spinner and no API-error text, so it is
invisible to the stall patterns and used to read as a healthy idle role,
silently parking the whole team. The watchdog classifies it `stalled-usage`
and auto-recovers: Escape dismisses the modal, a resume nudge is submitted,
and the cycle repeats on a flat cadence (`USAGE_RETRY_SEC`, default 300s)
indefinitely; a usage window returns on the account's schedule, not the
team's, so there is no give-up. On entry the operator gets one notice of class
`info` per role and hour (`USAGE_PUSH_DEDUPE_SEC`; the daily digest, no push).
When the role's refusal names a reset further away than `USAGE_WALL_PAGE_SEC`
(default 7200s) the retry cadence drops to `USAGE_WALL_PROBE_SEC` (default
1800s), and only a reset at least `USAGE_WALL_MULTIDAY_SEC` (default 86400s)
away pages the operator, once per wall. Once a role has stayed off the usage
dialog for `USAGE_RECOVERED_CONFIRM_SEC` (default 600s; the retry path blips),
the watchdog sends the **orchestrator** one wake-up nudge saying the outage may
be over (deduped per `USAGE_WAKE_DEDUPE_SEC`, default 3600s): workers resume
their own aborted turns when usage returns, but an orchestrator that was idle at
its prompt when the outage began has no turn to resume, and without the nudge a
fully recovered team sat undispatched until a human noticed.

```bash
# Any ntfy topic works (account-free; open it in the ntfy phone app):
export NTFY_URL=https://ntfy.sh/orch-<your-handle>-<random>
bin/run.sh ...
```

### Crash recovery (tmux-watchdog)

`tmux` itself can disappear in some environments: a systemd cleanup of
transient scopes, a WSL2 suspend/resume, a `daemon-reload` from unrelated
tooling. When that happens, every role process dies with the tmux server.
[`bin/tmux-watchdog.sh`](./bin/tmux-watchdog.sh) polls the team session every
15 seconds; if the session is gone while `$TEAM_DIR/active` still names live
roles, it flips `$TEAM_DIR/health/tmux.json` to `state=crashed`, drops
`$TEAM_DIR/CRASH-DETECTED.md` with the recovery command, appends an event to
`$TEAM_DIR/audit/tmux.log`, and pages the operator.

While the session is alive and `$TEAM_DIR/active` has entries, each poll also
restarts any of these daemons that died: the api, compaction, permission-mode,
host-RAM and disk/tmp watchdogs, the observer and the intake poller (each
restart is logged and filed as `info`). Disable the watchdog with
`TMUX_WATCHDOG_DISABLED=1`.

The watchdog **does not auto-restart** the team. Recovery still goes through the
operator (auto-restart is dangerous if the cause is still present). It also
takes a forensic snapshot of every window every 60 seconds into
`$TEAM_DIR/snapshots/<window>.txt`, so post-mortem material survives the crash.
The orchestrator launcher uses `setsid` to detach the tmux server from its
spawning shell's user-session scope, which removes the most common trigger
(session-cleanup events targeting the spawning shell sweeping the tmux server
with it).

Per-role context is lost on a crash, but the ledger lets the orchestrator
re-brief each role on its current unit in a few hundred tokens. Recovery flow
detail in [`docs/incident-2026-05-26-tmux-scope-cleanup.md`](./docs/incident-2026-05-26-tmux-scope-cleanup.md).

### Context cost control (compaction-watchdog)

Claude Code only auto-compacts a session when its context approaches the window
limit, and a near-full window is the most expensive state to run in: every turn
re-reads a very large cached context. On a long orchestrator run that dominates
cost. [`bin/compaction-watchdog.sh`](./bin/compaction-watchdog.sh) is a
pure-shell supervisor daemon that compacts the orchestrator and every top-tier
role **early**, at an idle task boundary, so the run spends most of its life in
a small, cheap context.

Each scan it acts only at a genuine "good moment": the target pane has been
unchanged for `COMPACT_IDLE_SEC` (a task boundary, and proof nothing is
streaming, so if the operator is mid-type the daemon stands down), no turn is in
progress (`esc to interrupt` absent), and the input line is empty or shows only
dim autocomplete shadow text (real unsubmitted text is left alone). It then
probes context with `/context` and picks the **right moment** with two
model-keyed thresholds per role, agent-cooperative first. A role is top tier
when its model record (`$TEAM_DIR/models/<role>`) names the top tier's model:
`TEAM_MODEL_TOP`, else `fable`, as `model_for` resolves it.

- at the nudge threshold (default 80, 70 for a top-tier role; `COMPACT_NUDGE_PCT`
  overrides both) it does **not** force anything. It types a
  `[compaction-watchdog]` message asking the session, at its next safe
  checkpoint (ledger/state written, no subagent running), to run
  `touch "$TEAM_DIR/health/compact-request-<role>"` and end its turn; a session
  cannot run `/compact` itself (built-in commands are not available to the
  model), so the watchdog sends `/compact` when it next finds the pane idle with
  that file present. The agent knows a semantically safe point better than any
  pane heuristic;
- at the force threshold (default 90, 85 for a top-tier role;
  `COMPACT_FORCE_PCT` overrides both) it force-sends
  `/compact <focus instructions>` as a backstop. By then auto-compact is
  imminent anyway, so a controlled forced compaction is the safer of two
  certainties.

The orchestrator re-reads its ledger/state after compaction, so no working
knowledge is lost. The daemon makes no Claude API call, so it cannot itself be
rate-limited. `COMPACT_NUDGE_DEBOUNCE` / `COMPACT_DEBOUNCE_SEC` bound how often it
nudges / forces. Disable with `COMPACT_WATCHDOG_DISABLED=1`. Its lifecycle matches
the api-watchdog (started at launch, re-ensured on orchestrator (re)start and role
add, self-healed by the tmux-watchdog).

The `/context` probe (which types keystrokes) targets window 0 plus every
top-tier-model role; targets are re-enumerated each cycle, so a role spawned,
retired or re-modelled mid-run is picked up. The passive **ceiling guard**, a
capture+grep for `Context limit reached` / `Compaction failed` that works even
mid-turn, covers **every** window. A session that slips past both thresholds
during a long turn and lands on the terminal "Compaction failed" state is
escalated: the orchestrator auto-recovers via `/clear` + a rebrief from
`state.md`; a worker gets a durable marker, an operator notice of class
`action`, and a retire+respawn request posted into the orchestrator pane.
Before the guard covered all windows, a default-model worker in that state was
invisible to the daemon and stalled the run until a human noticed.

A probe that parses empty for 3 consecutive cycles (`COMPACT_PROBE_FAIL_ALARM`)
or fails the startup check makes the role probe-blind, so a Claude Code
`/context` format change is never silent: the watchdog writes
`$TEAM_DIR/health/compaction-probe-blind-<role>.md`, logs it (no operator
notice: nobody can act on it from a phone), drives a `/compact` on that pane,
and for a worker tells the orchestrator pane.

### Operator paging (what reaches the phone)

Every push to the operator goes through one library, [`bin/lib/notify.sh`](./bin/lib/notify.sh)
(CLI: `bin/notify-operator.sh TITLE MESSAGE [page|action|info]`). Three classes: `page`
(a human must act now; a repeat for the same subject is pushed again at most every 30
minutes while its sender keeps raising it), `action` (a human must
act today; one per subject per six hours, queued outside working hours), `info` (never
pushed alone; one silent digest a day). Deny by default: the daemons' legacy one-line
notices map to `action` or `info`, and nothing pages unless its call site says `page`.
During a maintenance mute (`--mute <until>`) an `action` is dropped (logged, not queued), a
`page` still goes out prefixed `[maintenance]`, and `info` is unaffected. Every decision is
one line in `$TEAM_DIR/reports/operator-pings.log`. The policy, the
case it was built from and the call-site migration list are in
[`docs/OPERATOR-PAGING.md`](./docs/OPERATOR-PAGING.md).

### Standing rules that survive compaction

A rule that lives only in the conversation is gone at the next compaction. The pattern in
[`docs/STANDING-RULES.md`](./docs/STANDING-RULES.md): a ten-line card
(`RULES-IN-FORCE.md`, template in [`RULES-IN-FORCE.example.md`](./RULES-IN-FORCE.example.md))
pasted at the top of the project `CLAUDE.md`; a hook that re-prints it at every session
start and after every compaction and prints measured deviations on each prompt; and tool
gates in [`bin/hooks/`](./bin/hooks) that refuse a whole-file read over 200 lines, a long
outbound message without a logged draft pass, or a thinking-model subagent past its daily
cap, and that write the subagent call log themselves. The same directory holds the gate on
`rm` with a glob or a variable in the path, the outbound-reply gate and its send recorder,
a Stop hook that keeps a role from ending its turn with its bus reader unarmed, and the git
`pre-push` privacy scan. Which hook goes on which event: [`docs/ENFORCEMENT.md`](./docs/ENFORCEMENT.md).

### The observer audit

[`bin/observer.sh`](./bin/observer.sh) is a read-only daemon that recommends, never acts.
Besides sizing the roster it now audits from primary sources every pass (crontab jobs,
daemon liveness, what reached the phone, ledger freshness, git state per working tree,
stale markers, the unit table, subagent calls per class) and must cite evidence for each
item. By default it calls `sonnet` every 15 minutes (`OBSERVER_MODEL`, `OBSERVER_INTERVAL`);
a stronger model at a lower cadence gives a more thorough audit. While its decision inputs
are unchanged it skips the model call, but makes one at least every
`OBSERVER_FORCE_CALL_EVERY` cycles (default 8); after `OBSERVER_FAIL_ALERT_AFTER` (default
3) consecutive failed model calls it sends one bus message to the orchestrator.

[`bin/capability-probe.sh <probes.conf>`](./bin/capability-probe.sh) proves, read-only or
dry-run, that the team can still perform every privileged action its work depends on, for
example before and after a permission change; a FAIL is an `action` notice, and the
observer's audit reads its last result. Probe file format and options:
[`docs/CAPABILITY-PROBE.md`](./docs/CAPABILITY-PROBE.md).

### Daemons reach the bus, and reload themselves

The `/is` sender is session-bound: from a daemon or cron job it cannot find a listener
and fails silently. Daemons use [`bin/bus-send.py`](./bin/bus-send.py), which registers a
named transient peer with the shared token. Every long-running daemon sources
[`bin/lib/self-reload.sh`](./bin/lib/self-reload.sh) and re-executes itself when its own
source or a library it tracks changes, so a fix on disk is a fix in memory without a
manual restart; the reload is written to `$TEAM_DIR/audit/`.

### Daemon lifecycle

A running team has several detached supervisor daemons alongside the role
sessions. They are **not** part of any role's context; they are plain `nohup`
background processes recorded by pidfile under `$TEAM_DIR`. One function,
`ensure_team_daemons` in [`bin/lib/team-spawn.sh`](./bin/lib/team-spawn.sh),
starts the whole set; `launch-team.sh`, `start-orchestrator.sh` (including a
recovery) and `add-role.sh` all call it. Its `start_*` helpers are
**idempotent**: the api-watchdog and the intake poller are judged running when
their per-`TEAM_DIR` flock is held; the others when their pidfile names a live
process that is really that daemon, not a reused pid. The one exception is the
compaction-watchdog: its helper reaps a running instance and starts a fresh one
on every call. Opt-outs, each `=1`: `API_WATCHDOG_DISABLED`,
`COMPACT_WATCHDOG_DISABLED`, `TMUX_WATCHDOG_DISABLED`,
`PERMISSION_MODE_WATCHDOG_DISABLED`, `HOST_RAM_WATCHDOG_DISABLED`,
`DISK_TMP_WATCHDOG_DISABLED`, `CHROME_SUPERVISOR_DISABLED`, `OBSERVER_DISABLED`,
`INTAKE_POLLER_DISABLED`.

| Daemon | Purpose | Started / re-ensured by | Stopped by |
|---|---|---|---|
| `api-watchdog.sh` | auto-recover API rate-limit / network and usage-limit stalls, nudge wedged roles, report roles blocked on a prompt | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and **self-healed every 15s by `tmux-watchdog.sh`** | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `compaction-watchdog.sh` | compact the orchestrator and top-tier roles early at idle boundaries to keep context (and cost) off the auto-compact ceiling; ceiling guard on every window | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and self-healed by `tmux-watchdog.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `permission-mode-watchdog.sh` | hold every pane in the permission mode the run was launched with, so drift cannot park the run on a confirmation prompt | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and self-healed by `tmux-watchdog.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `tmux-watchdog.sh` | detect tmux-server crash, snapshot panes, self-heal the daemons marked "self-healed" in this table | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `host-ram-watchdog.sh` | host OOM guard; writes the band marker `bin/gates/heavy-work-gate.sh` reads | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and self-healed by `tmux-watchdog.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `disk-tmp-watchdog.sh` | disk / tmp usage guard; also runs `bin/rotate-team-logs.sh` once per cycle to cap run-log size | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and self-healed by `tmux-watchdog.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `chrome-supervisor.sh` | un-wedge roles stuck on a hung chrome MCP call (not self-healed) | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| `observer.sh` | periodic model-backed advice and audit; recommends, never acts | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and self-healed by `tmux-watchdog.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |
| intake poller (optional; `$INTAKE_POLLER` or `<working-tree>/scripts/poller.py`) | ping the orchestrator on external traffic | `launch-team.sh`, `start-orchestrator.sh` (incl. recovery), `add-role.sh`, and self-healed by `tmux-watchdog.sh` | `stop-team.sh`, `panic.sh` (also via `reset.sh`), `cleanup.sh --force` |

**The lifecycle invariant:** any path that brings the team (or just the
orchestrator) up must ensure the watchdogs, not only the cold `launch-team.sh`
path. `start-orchestrator.sh` is also the **recovery** entry point (relaunch the
orchestrator while its roles still live); it does not re-run `launch-team.sh`, so
it ensures the daemons itself. Belt-and-braces, the always-on `tmux-watchdog`
restarts the `api-watchdog` within one 15s poll if it ever dies. This closes a
real hole: a recovery via `start-orchestrator.sh` after a `stop-team.sh` (which
kills the api-watchdog) would otherwise leave the watchdog absent, so every
transient rate-limit stall halts the team until a human nudges it.

**Restart reaps the daemon set first (reap-before-spawn).** `panic.sh` reaps
EVERY detached daemon by pidfile (the api-watchdog, intake poller, observer,
chrome-supervisor, tmux-watchdog, permission-mode-watchdog, and ALL resource watchdogs: compaction /
host-ram / disk-tmp) *and each one's backgrounded `sleep` child*, which
inherits the per-`TEAM_DIR` flock fd. Reaping the child (via `pkill -P`) frees
the singleton lock immediately, so a resume's fresh daemon wins the lock instead
of exiting-at-birth beside a surviving old instance. The compaction-watchdog
spawner also reaps before it spawns (`_reap_prior_daemon` in `team-spawn.sh`);
the other spawners start nothing while their daemon is alive, and every daemon
re-executes itself when its code changes (self-reload, above), so a restart
does not leave a long-lived instance running pre-fix logic. Net: a restart
cannot leak a second set (the 2026-07-20 duplicate-watchdog failure, where an
old-code instance survived every restart and doubled each `/compact`
keystroke). If you ever see two of one
watchdog: `pgrep -af '<name>-watchdog.sh'` should show exactly one; if not,
`panic.sh` then resume.

### Nightly memory consolidation (dreaming)

The run's knowledge ledgers grow append-only: `state.md` accretes superseded
derive/challenge/re-derive chains, the decisions file keeps every intermediate
verdict of closed sagas, `observer/history.md` restates a near-identical
snapshot every cycle. [`bin/dreamer.sh`](./bin/dreamer.sh) is a cron-driven,
quiescence-gated consolidator (it runs only when
[`bin/role-activity.sh`](./bin/role-activity.sh) reads every roster role's pane
as `idle`, not working or delegating to subagents): the model emits an **edit script** against
exact section headers (never a wholesale rewrite), application is mechanical,
removed content is archived verbatim BEFORE an atomic swap, fresh/undated
sections are untouchable, and every cycle leaves a reviewable report + diffs
under `dreams/`. Strategic facts can be promoted into a durable memory bank
(`DREAMER_MEMORY_DIR`); proposed changes to tracked files are only ever staged
for operator review (B13's propose-and-review rule).
[`bin/night-janitor.sh`](./bin/night-janitor.sh) is its deterministic sibling
for non-knowledge bulk (ledger backups, re-downloadable ticket media, archive
expiry, opt-in bus retention, and with `NJ_DOCKER_BUILDER_PRUNE=1` a
`docker buildx prune` of build cache older than 23 hours), dry-run by default.
Neither runs from the launcher: wire both into cron. Full design and cron
examples: [docs/dreaming.md](./docs/dreaming.md).

### Rate limits and cost

Claude Code retries transient failures (429 / 529 / timeouts) with backoff. For
long runs, `CLAUDE_CODE_MAX_RETRIES=40` and `API_TIMEOUT_MS=900000` harden it;
stagger starts (the launcher already sleeps 1s between roles) and reduce
concurrency or model size on sustained limits. Right-size the team, keep the
per-role model tiers (top tier to judge, `opus` to produce, `sonnet`/`haiku` for
mechanical work; see [Roles](#roles)), let idle roles idle (a
waiting `/is` session costs nothing), and offload schedulable work to cloud
routines.

## Non-code work (legal, research, docs pipelines)

The system is domain-neutral. Beyond coding, the team can do research, writing,
slide content, legal analysis, anything the operator briefs. The non-code
pipeline rests on two pieces:

- **Reference role library** at [`roles/`](./roles): structural references
  (`researcher`, `writer`, `editor`, `fact-checker`, `copy-editor`,
  `peer-reviewer`, `doc-integrator`) plus three legal references (`paralegal`,
  `lawyer`, `swiss-law-specialist`). Area specialists are authored on the fly.
- **Gate library** at [`bin/gates/`](./bin/gates) wraps non-binary checks as
  exit-0 commands so a non-code unit's `verify:` line can use them:

  | Gate | What it checks |
  | :-- | :-- |
  | `structure.sh <art> <rules.yml>` | Required headings, word and section counts |
  | `link-live.sh <path>` | Every URL in the artifact returns 2xx |
  | `cite-resolve.sh <art> <bib>` | Every cite has a bibliography entry, and vice versa |
  | `md-lint.sh <path>` | Markdown well-formed (`markdownlint-cli2`) |
  | `office-wellformed.sh <file>` | `.docx` / `.pptx` opens cleanly and has content |
  | `llm-judge.sh <art> <rubric.md>` | LLM-judge against a rubric, K-vote, audit log |
  | `rubric-judge.sh <art> <rubric.md>` | Thin wrapper on `llm-judge` for per-unit rubrics |
  | `cite-support.sh <art>` | LLM-judge that cited sources support the claims |

  Example `verify:` line:
  `bash $ORCH_HOME/bin/gates/structure.sh draft.md rules.yml && bash $ORCH_HOME/bin/gates/cite-resolve.sh draft.md refs.md`

Tools: Pandoc for Markdown ↔ DOCX / PDF (`pandoc --citeproc
--bibliography=refs.bib --csl=style.csl in.md -o out.docx`). GPT Researcher via
the `gptr-mcp` MCP server can be wired into a researcher role for web research.

## Engineering standards

Binding on every role; the tight version is in [`CLAUDE.md`](./CLAUDE.md),
loaded into every session automatically.

- **Verify, do not guess.** Every load-bearing claim traces to a file read, a
  command run, or a test reproduced.
- **Small, surgical changes.** Touch only the assigned unit; no drive-by edits.
- **Test with real tools.** Run the suite; drive a real browser via the
  chrome-devtools MCP; compare bytes for binary output. Done means seen to work.
- **No silent partial work.** Finish the unit, or report the blocker and what
  is left.
- **Push the work branch to origin.** Pushing a work or integration branch is
  routine and operator-authorized, not a human handoff. The human gate is for
  merging into a protected default or production branch, prod deploys, and
  destructive pushes.
- **Scripts over judgement.** Deterministic, rule-based work (spawn, teardown,
  validation, gates, status, scaffolding) is a script under [`bin/`](./bin),
  not an LLM turn.

## When to use this vs native primitives

Claude Code already ships two multi-agent primitives. This orchestrator is a
third layer on top of them, with a different shape.

| Situation | Reach for |
| :-- | :-- |
| Short focused side task whose result fits back in context (search, one-off analysis, a review pass) | Subagent |
| Cost-routing verbose work to a cheaper model with tool restrictions | Subagent |
| Self-contained parallel burst, peers that discuss and challenge, no resume needed | Agent Teams |
| Cross-layer feature where each teammate owns a slice, one sitting | Agent Teams |
| Work that must pass an enforced verify + scope gate before it counts as done | This orchestrator |
| Long-lived roles whose accumulating context is the deliverable; resume across restarts | This orchestrator |
| Unattended multi-round runs needing watchdog, isolation, kill-switches, audit ledger | This orchestrator |
| Multiple teams running at once in one clone | This orchestrator |
| Non-code substrate (legal, docs pipelines) with custom gates | This orchestrator |

Full comparison and the honest moat in
[`docs/native-agents-comparison.md`](./docs/native-agents-comparison.md).

## Project layout

```
claude-orchestrator/
├── README.md  CLAUDE.md  STATUS.md  BACKLOG.md  LICENSE
├── RULES-IN-FORCE.example.md # template for the standing-rules card
├── .claude/settings.json     # deny-list (hook wiring example: docs/STANDING-RULES.md)
├── roles/                    # one prompt per role (incl. integrator, communicator)
│   └── _TEMPLATE.md          # for orchestrator-authored ad-hoc roles
├── goals/                    # per-feature briefs (_TEMPLATE.md + curated demos)
├── tasks/                    # per-unit task briefs (_TEMPLATE.md)
├── templates/state.md        # ledger format -> $TEAM_DIR/state.md
├── docs/                     # paging policy, standing rules, verification disciplines,
│                             # authority model, model policy, dreaming, incident notes
├── bin/
│   ├── run.sh                # the one-command entry point
│   ├── team-env.sh           # per-clone bus port + tmux session (sourced)
│   ├── lib/                  # sourced helpers: team-spawn.sh, roster.sh, notify.sh,
│   │                         # self-reload.sh, compaction-detect.sh, status-hook.sh
│   ├── gates/                # non-code gate library
│   ├── hooks/                # standing-rules hook and the refusing tool gates
│   ├── tests/                # pure shell tests, one per mechanism; run-all.sh runs them
│   ├── start-orchestrator.sh launch-team.sh stop-team.sh reset.sh panic.sh
│   ├── add-role.sh retire-role.sh   # dynamic team scaling
│   ├── communicator.sh       # operator surface
│   ├── api-watchdog.sh tmux-watchdog.sh compaction-watchdog.sh watchdog.sh
│   ├── permission-mode-watchdog.sh host-ram-watchdog.sh disk-tmp-watchdog.sh
│   ├── observer.sh observer-github-groundtruth.sh dreamer.sh night-janitor.sh
│   ├── notify-operator.sh bus-send.py privacy-scan.sh
│   ├── new-goal.sh new-project.sh worktree.sh unit-start.sh
│   ├── verify-unit.sh check-scope.sh preflight-deploy.sh rotate-team-logs.sh
│   └── team-status.sh team-watch.sh team-broadcast.sh team-logs.sh inbox.sh
└── .team-<run-id>/           # transient per-run: ledger, briefs, active record, logs
```

**Tests.** `bash bin/tests/run-all.sh` runs the whole suite, one file at a time:
every `bin/tests/*test.sh`, then `tests/b9/*.sh`. Give file names (bare names are
looked up in `bin/tests/` and `tests/b9/`) to run a subset; `--list` prints the
selection and runs nothing; `RUN_ALL_TIMEOUT` (default 600) bounds each file in
seconds. It prints one line per file, the skips and the failures with their log
paths, and exits 0 only when no file failed. It runs every file with the team
identity variables removed, so no test inherits a live run's `TEAM_RUN_ID`,
`TEAM_DIR` or tmux socket; a test under `bin/tests/` must also source
`bin/tests/lib/isolate.sh` before `bin/team-env.sh` (CLAUDE.md, "Tests are
isolated, always").

## See also

- [`1-fares/claude-code-inter-session`](https://github.com/1-fares/claude-code-inter-session):
  the `/is` bus. Required prerequisite. Fork of
  [`yilunzhang/claude-code-inter-session`](https://github.com/yilunzhang/claude-code-inter-session)
  (MIT, original author Yilun Zhang).
- [`STATUS.md`](./STATUS.md): what is built versus pending, with the locked
  design decisions behind it.
- [`BACKLOG.md`](./BACKLOG.md): forward-looking work items.
- [`docs/`](./docs): the operator paging policy, standing rules, verification
  disciplines, the authority model, model policy, dreaming, the version pin,
  default-to-act, the native-agents comparison, and incident reports.
- Claude Code features this pattern composes:
  [agent teams](https://code.claude.com/docs/en/agent-teams),
  [routines](https://code.claude.com/docs/en/routines),
  [`/goal`](https://code.claude.com/docs/en/goal),
  [`/loop`](https://code.claude.com/docs/en/scheduled-tasks),
  [permissions](https://code.claude.com/docs/en/permissions).

## License

MIT. See [LICENSE](./LICENSE).

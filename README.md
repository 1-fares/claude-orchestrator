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

That is the full install. The two repos live as siblings; the orchestrator finds
the `/is` skill through Claude Code, not through a file path.

## Run a goal

```bash
bin/run.sh
```

`bin/run.sh` allocates a fresh `TEAM_RUN_ID`, spawns the orchestrator into a
dedicated tmux session, and attaches you. You land in the orchestrator (window
0). The orchestrator then asks you, in the session:

1. **Working tree.** A new path to create, an existing repo to work on, or this
   clone (greenfield).
2. **What to build or change.** Free text: a sentence, a paragraph, a pasted
   issue.
3. **Optional constraints, mode (interactive / autonomous), team-size cap.**

It echoes your brief back, writes the goal file, copies `templates/state.md`
into `.team-<run-id>/state.md` as the run ledger, breaks the work into units,
and presents a **READY** summary. Reply `go` to start, or any adjustment
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

## Drive the team

By default the orchestrator and all roles share one tmux session, orchestrator =
window 0, roles = windows 1, 2, ...

```
INSIDE TMUX
  prefix <N>     switch to window N        prefix w     window list
  prefix n / p   next / prev window        prefix d     detach (SAFE)

MONITOR (from any terminal)
  bin/team-status.sh               one-glance dashboard
  bin/team-watch.sh                live dashboard
  bin/team-logs.sh [<role>]        per-role message history (durable)

CONTROL
  bin/team-broadcast.sh "<msg>"    inject to every role from outside the bus
  bin/stop-team.sh                 end roles, keep orchestrator
  bin/reset.sh                     end everything + clear this run's state
  bin/cleanup.sh                   dry-run; detects orphans + misfires
  bin/cleanup.sh --force --purge   apply (scoped to this clone's team only)
  bin/panic.sh                     emergency stop (last resort)
```

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
bus port, tmux session, and state directory (`.team-<run-id>/`). Two teams in
one clone never share state. To address a specific run from outside:

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
| **Communicator** | `communicator` | Two-way liaison with the operator (TUI + the dashboard chat panel). Curated, not auto-generated. |
| **Analyst** | `analyst` | Turning a vague goal into testable requirements and acceptance criteria. |
| **Architect** | `architect` | System and interface design, technology choices, breaking work into units. |
| **Implementer** | `implementer<N>` | Writing code for one assigned unit, small and surgical, in its own worktree. |
| **Tester** | `tester<N>` | Tests and adversarial cases; red-before-green capture; reproducing bugs. |
| **Reviewer** | `reviewer<N>` | Independent correctness review; a cited checklist artifact. |
| **Integrator** | `integrator` | Merging units, conflict resolution, integration build. Keeps merge off the orchestrator. |
| **DevOps** | `devops` | Build, environments, dependencies, tooling, CI. |
| **Deployment** | `deployment` | Release, post-release verification, rollback, deploy preflight. |

Extended roles, added when the goal calls for them: **frontend** (`frontend<N>`,
builds the UI), **researcher** (spikes), **security reviewer** (red-team),
**tech writer** (docs).

**Roles are open-ended.** If a goal needs a role with no `roles/<base>.md` (a UX
designer, an Android developer, a lawyer, a market analyst), the orchestrator
authors one before launch from [`roles/_TEMPLATE.md`](./roles/_TEMPLATE.md),
tailored to that role and the goal. Curated non-code references are already in
[`roles/`](./roles): `researcher`, `writer`, `editor`, `fact-checker`,
`copy-editor`, `peer-reviewer`, `doc-integrator`, plus three cross-cutting legal
references (`paralegal`, `lawyer`, `swiss-law-specialist`). Area specialists
(e.g. `employment-lawyer1`, `tenancy-lawyer1`) are not predefined; they are
authored on the fly so the operator can pursue any topic without growing the
curated set.

Keep the team as small as the goal allows. On a local subscription, every role
defaults to the best model (Opus); drop a role to a faster model only for speed.
On API-paid remote agents, invert it: bulk on Sonnet, Opus to check. Tune
`model_for()` in [`bin/lib/team-spawn.sh`](./bin/lib/team-spawn.sh). Current ids:
`opus` (`claude-opus-4-7`), `sonnet` (`claude-sonnet-4-6`), `haiku`
(`claude-haiku-4-5`).

## How it works

### The message bus (`/is`)

Coordination runs on the
[`/is` skill](https://github.com/1-fares/claude-code-inter-session), a separate
sibling project (install once, used by any number of orchestrator clones). Each
session joins with a role name, then messages flow peer-to-peer:

```
/is c orchestrator
/is s implementer1 --file tasks/parser.md          # assign a unit (file pointer)
/is s orchestrator 'status: parser done; verify green'
/is b 'standup: where is everyone?'                # broadcast to all roles
```

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
step, report, yield; the `/is` monitor wakes it on the next message, idle costs
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

The tester captures a red-before-green log pair; the reviewer produces a cited
checklist. The orchestrator may waive the gates for trivial units. Rejected,
partial, or out-of-scope work is never dropped: it becomes a new ledger unit.

A pluggable **gate library** at [`bin/gates/`](./bin/gates) covers non-code
units (`structure`, `link-live`, `cite-resolve`, `md-lint`, `office-wellformed`,
`llm-judge`, `rubric-judge`, `cite-support`). A goal's `tasks/<unit>.md`
`verify:` line wires one of these.

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
clean.

### Dynamic team scaling

The team is not frozen at the READY gate. Mid-run the orchestrator can grow or
shrink the roster:

- `bin/add-role.sh [--workdir DIR] <goal> <role> [--task <brief>]` spawns one
  role into the live session, enforces a soft cap (default 12, custom, or
  uncapped, set at start in `$TEAM_DIR/max-team-size`), refuses double-spawn,
  warns on reuse-before-spawn, writes a decision-log + roster line, and
  optionally pushes ntfy.
- `bin/retire-role.sh <role>` does a graceful single-role teardown scoped to
  that role only. It refuses if the role owns in-progress units; `--force`
  re-files them as `todo` first. Health and audit are archived to
  `$TEAM_DIR/retired/<role>/`.

**Pause vs retire** is a deliberate distinction. An idle role on the bus costs
nothing (the `/is` monitor holds it open with no API calls). So retire is not a
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

Two front-ends are wired up:

- **TUI**: `bin/communicator.sh` opens a Claude Code session in the
  `communicator` role in a new tmux window (or `--foreground` to run in the
  current terminal). Idempotent: a second invocation reattaches.
- **GUI**: a chat panel on the visual dashboard (below).

### Visual dashboard (second screen)

`bin/launch-team.sh` auto-starts [`bin/dashboard.sh`](./bin/dashboard.sh), a
read-only HTTP viewer designed for a second screen during a run. It serves a
force-directed graph of live roles plus a stats panel from data files under
`$TEAM_DIR` (roster, ledger, watchdog health, bus log). The launcher prints the
URL on start (`open http://127.0.0.1:<port>/`) and writes it to
`$TEAM_DIR/dashboard.url`. Loopback-only, no buttons; cleaned up by
`stop-team.sh`, `panic.sh`, `reset.sh`, and `cleanup.sh`.

Standalone (no live team needed; degrades gracefully):

```bash
bin/dashboard.sh                       # auto-pick port; $TEAM_DIR or newest .team-*
bin/dashboard.sh --port 8765           # fixed port
bin/dashboard.sh --team-dir .team-r123 # point at a specific run
```

Disable auto-start with `DASHBOARD_DISABLED=1`. Fix the port at launch with
`DASHBOARD_PORT=N`.

### Remote control from a phone

Primary: **Claude Code Remote Control** (`/remote-control`, alias `/rc`).
First-party, outbound-only, scan the QR with the Claude mobile app, and the
conversation syncs to the phone with push notifications when Claude needs input.
This covers the 95% case: reading orchestrator output, answering clarifying
questions, typing replies at READY gates. It does not cover role-window
scrollback or arbitrary shell commands on the host.

Escape hatch for when `/remote-control` is not enough (a tester's scrollback, a
manual cleanup, switching between parallel runs):

- `bin/team-status.sh --mobile`: ~40-column compact dashboard.
- `bin/inbox.sh`: every parallel run on this clone with attach + approve
  commands.
- `bin/approve.sh [<text>]`: send `<text>` (default `go`) to a specific run's
  orchestrator pane (`TEAM_RUN_ID=<id> bin/approve.sh`).

A signed-action-URL HTTP hook is also in the tree
(`bin/notify-hook.py` + `bin/sign-action-url.sh` + `bin/notify-via-ntfy.sh`)
for tap-to-approve / tap-to-pause buttons embedded in ntfy pushes. It is off by
default; URLs carry HMAC with a 30-minute TTL. Reaching the host from the phone
(Tailscale, Cloudflare Tunnel, anything else) is a separate problem and is not
covered here.

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

### API rate-limit resilience (api-watchdog)

Transient Anthropic API rate-limit or network errors stall a role's pane with a
`try again` prompt; in a multi-role run, an unwatched stall halts the team
silently. [`bin/api-watchdog.sh`](./bin/api-watchdog.sh) is a supervisor daemon
whose lifecycle is described in [Daemon lifecycle](#daemon-lifecycle) below — it
is started at launch, re-ensured on every orchestrator (re)start and role add,
and self-healed by the tmux-watchdog, so it can never be silently absent while a
team runs. It is a pure-shell daemon that scans every team window,
detects the stall, and sends `try again` with exponential backoff
(30s → 60s → 120s → 300s → 600s, max 5 retries). Per-role state lives in
`$TEAM_DIR/health/<role>.json` and is visible in the `HEALTH` column of
`bin/team-status.sh`. With `NTFY_URL` set, it pushes ntfy on state changes
(first stall, recovery, give-up). The watchdog makes no Claude API call so it
cannot itself be rate-limited. Patterns live in `bin/api-watchdog.patterns`.
Disable with `API_WATCHDOG_DISABLED=1`.

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
`$TEAM_DIR/audit/tmux.log`, and pushes ntfy.

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

### Daemon lifecycle

A running team has several detached supervisor daemons alongside the role
sessions. They are **not** part of any role's context; they are plain `nohup`
background processes recorded by pidfile under `$TEAM_DIR`. The start helpers
([`bin/lib/team-spawn.sh`](./bin/lib/team-spawn.sh) `start_*`) are **idempotent**
— each checks its pidfile and verifies the pid is really that daemon (not a
reused pid) before deciding to (re)start, so calling them repeatedly is safe.

| Daemon | Purpose | Started / re-ensured by | Stopped by |
|---|---|---|---|
| `api-watchdog.sh` | auto-recover API rate-limit / network stalls | `launch-team.sh`, **`start-orchestrator.sh`** (incl. recovery), `add-role.sh`, and **self-healed every 15s by `tmux-watchdog.sh`** | `stop-team.sh`, `panic.sh`, `cleanup.sh` |
| `tmux-watchdog.sh` | detect tmux-server crash, snapshot panes, self-heal the api-watchdog | `launch-team.sh`, `start-orchestrator.sh`, `add-role.sh` | `stop-team.sh`, `panic.sh`, `cleanup.sh` |
| `chrome-supervisor.sh` | un-wedge roles stuck on a hung chrome MCP call | `launch-team.sh`, `add-role.sh` | `stop-team.sh`, `panic.sh`, `cleanup.sh` |
| `communicator` / observer | bus + optional efficiency observer | `launch-team.sh`, `add-role.sh` | `stop-team.sh` |

**The lifecycle invariant:** any path that brings the team (or just the
orchestrator) up must ensure the watchdogs — not only the cold `launch-team.sh`
path. `start-orchestrator.sh` is also the **recovery** entry point (relaunch the
orchestrator while its roles still live); it does not re-run `launch-team.sh`, so
it ensures the daemons itself. Belt-and-braces, the always-on `tmux-watchdog`
restarts the `api-watchdog` within one 15s poll if it ever dies. **2026-06-01
incident that motivated this:** an orchestrator was recovered via
`start-orchestrator.sh` after a `stop-team.sh` that had killed the api-watchdog;
nothing restarted it, so it was absent for a full day and every transient
rate-limit stall halted the team until a human nudged it. Both the
`start-orchestrator` ensure and the `tmux-watchdog` self-heal close that hole.

### Rate limits and cost

Claude Code retries transient failures (429 / 529 / timeouts) with backoff. For
long runs, `CLAUDE_CODE_MAX_RETRIES=40` and `API_TIMEOUT_MS=900000` harden it;
stagger starts (the launcher already sleeps 1s between roles) and reduce
concurrency or model size on sustained limits. Right-size the team, tier models
by where work runs (Sonnet for bulk, Opus to check), let idle roles idle (a
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
├── .claude/settings.json     # deny-list
├── roles/                    # one prompt per role (incl. integrator, communicator)
│   └── _TEMPLATE.md          # for orchestrator-authored ad-hoc roles
├── goals/                    # per-feature briefs (_TEMPLATE.md + curated demos)
├── tasks/                    # per-unit task briefs (_TEMPLATE.md)
├── templates/state.md        # ledger format -> $TEAM_DIR/state.md
├── docs/                     # default-to-act, native-agents comparison, incident notes
├── bin/
│   ├── run.sh                # the one-command entry point
│   ├── team-env.sh           # per-clone bus port + tmux session (sourced)
│   ├── lib/                  # sourced helpers: team-spawn.sh, roster.sh
│   ├── gates/                # non-code gate library
│   ├── dashboard/            # second-screen HTTP server + static assets
│   ├── start-orchestrator.sh launch-team.sh stop-team.sh reset.sh panic.sh
│   ├── add-role.sh retire-role.sh   # dynamic team scaling
│   ├── communicator.sh dashboard.sh # operator surfaces
│   ├── api-watchdog.sh tmux-watchdog.sh watchdog.sh
│   ├── new-goal.sh new-project.sh worktree.sh unit-start.sh
│   ├── verify-unit.sh check-scope.sh preflight-deploy.sh
│   └── team-status.sh team-watch.sh team-broadcast.sh team-logs.sh inbox.sh
└── .team-<run-id>/           # transient per-run: ledger, briefs, active record, logs
```

## See also

- [`1-fares/claude-code-inter-session`](https://github.com/1-fares/claude-code-inter-session):
  the `/is` bus. Required prerequisite. Fork of
  [`yilunzhang/claude-code-inter-session`](https://github.com/yilunzhang/claude-code-inter-session)
  (MIT, original author Yilun Zhang).
- [`STATUS.md`](./STATUS.md): what is built versus pending, with the locked
  design decisions behind it.
- [`BACKLOG.md`](./BACKLOG.md): forward-looking work items.
- [`docs/`](./docs): supplementary notes (default-to-act, native agents
  comparison, incident reports).
- Claude Code features this pattern composes:
  [agent teams](https://code.claude.com/docs/en/agent-teams),
  [routines](https://code.claude.com/docs/en/routines),
  [`/goal`](https://code.claude.com/docs/en/goal),
  [`/loop`](https://code.claude.com/docs/en/scheduled-tasks),
  [permissions](https://code.claude.com/docs/en/permissions).

## License

MIT. See [LICENSE](./LICENSE).

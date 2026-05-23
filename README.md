# claude-orchestrator

A pattern for building software with a team of Claude Code sessions.

> Under active revision following a design review. [STATUS.md](./STATUS.md) holds
> the locked design decisions and what is built versus pending; where this README
> and STATUS disagree, STATUS is current. The ledger, structured handoffs,
> verify/scope gates, the integrator role, and cadence modes are landing in
> stages.

One session, the **orchestrator**, holds the goal and coordinates a set of
specialised role sessions (architect, implementer, tester, and so on). The
sessions are independent Claude Code processes on the same machine; they talk
to each other over the [`/is` message bus](../claude-code-inter-session). The
orchestrator decides which roles are needed for a given goal, launches them,
hands out work, and integrates the results.

This repository is the pattern itself: the role prompts, a launcher, an
engineering charter, and the conventions that hold a team together. Point it at
a new goal and it runs again.

## Distribution: clone per project

The orchestrator is a template, not a shared home for every goal you ever run.
Clone it once per target project (GitHub "Use this template", or `git clone`),
so each project's orchestrator state, goals, and any role tweaks stay
segregated. Within a clone, `goals/` holds one brief per feature of that
project; across projects, you get a fresh clone.

Two ways the clone relates to the code it works on:

- **Greenfield:** build the new software inside the clone. The working tree is
  the clone itself; `goals/` holds the features you build into it.
- **Existing codebase:** clone the orchestrator beside the target repo and point
  the team at the code with `--workdir`. Role sessions run in the target tree
  (so they edit the right files and pick up that project's own `CLAUDE.md`),
  while the orchestrator's `CLAUDE.md`, role files, and goal are read by absolute
  path:

  ```bash
  bin/launch-team.sh --workdir ~/projects/some-app \
      goals/repo-bugfix.md implementer1 tester1
  ```

The role prompts, the engineering charter, and the launcher are constant across
every project the template is ever cloned into. Only the `goals/` brief, and the
`--workdir` you point at, change.

## Why a team, not one session

A single long session degrades on large work: context fills with detail from
every layer, and one role's mistakes (a half-finished refactor, a wrong
assumption) contaminate the rest. Splitting the work across sessions gives each
role its own clean context window, its own narrow remit, and its own
conversation history that grows in value over time. The implementer keeps the
design rationale; the tester keeps the regression suite; the reviewer keeps the
catalogue of edge cases already checked. None of them drowns in the others'
detail.

Claude Code has three concurrency primitives. This pattern uses all three, for
different jobs:

| Primitive | What it is | Used here for |
| :-- | :-- | :-- |
| **Subagents** (the `Agent` tool) | A worker spawned inside one session; its result returns to the caller, then it exits. | Short, throwaway fan-out inside a single role (e.g. "search these 30 files"). Cheap, no coordination. |
| **`/is` sessions** | Long-lived independent sessions messaging each other peer-to-peer over a localhost bus. | The team itself. Each role is a persistent `/is` session that accrues context across many rounds. |
| **Agent teams** (experimental) | A built-in lead-plus-teammates feature with a shared task list. | An alternative team substrate; see [Launching the team](#launching-the-team). |

The `/is` bus is the spine of this pattern because the roles are long-lived and
cross-project: a session can run for hours, keep its history, and be driven by
the orchestrator without restarting. Subagents reset between calls and agent
teams exit when their one task ends; neither sustains a multi-round role.

## Roles

The orchestrator is the only required session. Everything else is launched on
demand, in the count the goal needs (two implementers, three testers, none of
some). Each role has a prompt file in [`roles/`](./roles); the bus name is the
file name plus an optional digit, so `implementer1` and `implementer2` both read
`roles/implementer.md`.

### Core roles

| Role | Bus name | Owns |
| :-- | :-- | :-- |
| **Orchestrator** | `orchestrator` | The goal, team composition, work assignment, integration, the final call. |
| **Business analyst** | `analyst` | Turning a vague goal into concrete, testable requirements and acceptance criteria. |
| **Architect** | `architect` | System and interface design, technology choices, breaking work into units. |
| **Implementer** | `implementer<N>` | Writing code for an assigned unit; small, surgical changes. |
| **Tester** | `tester<N>` | Writing and running tests, adversarial cases, reproducing bugs. |
| **Reviewer** | `reviewer<N>` | Reading diffs for correctness; an independent check on the implementer. |
| **DevOps** | `devops` | Build, environments, dependencies, tooling, CI, the things that let work run. |
| **Deployment** | `deployment` | Release, rollout, post-release verification, rollback. |

On a local subscription run, every role defaults to the best model (Opus); drop
a role to a faster model only for speed. On API-paid remote agents, invert this:
run the bulk on Sonnet and have Opus check the result. See
[Cost](#cost).

### Extended roles, added when the goal calls for them

| Role | Owns |
| :-- | :-- |
| **Researcher** | Spikes and unknowns: library evaluation, reading external docs, prototypes. |
| **Security reviewer** | Adversarial review of the change; the red-team half of an attack/patch loop. |
| **Tech writer** | User-facing docs, READMEs, changelogs, API reference. |

Keep the team as small as the goal allows. Every extra session is another
context to coordinate and another draw on the shared rate limit (see
[Running unattended](#running-unattended-cost-permissions-rate-limits)). A
bug fix might be orchestrator plus one implementer plus one tester; a new
service might be the full core set.

## How it works

### The message bus (`/is`)

Coordination runs on the [`/is` skill](../claude-code-inter-session) (alias for
inter-session). Every session joins the bus with a role name, then messages
flow peer-to-peer:

```
/is c orchestrator                         # the orchestrator joins
/is c implementer1                          # an implementer joins
/is s implementer1 implement the parser in src/parse.c per architect's spec
/is s orchestrator status: parser done, 12 tests pass
/is b standup: where is everyone?           # broadcast to all roles
```

A received message is delivered to the other session as a prompt and **acted on
as an instruction by default**. This is what lets the orchestrator drive the
team. The receiver applies the same caution it would to user input: destructive
operations need explicit affirmative content, and ambiguous requests draw a
`question:` clarifier first. Reply prefixes (`status:`, `done:`, `answer:`,
`question:`) let the orchestrator route replies without re-reading every line.

For anything longer than a sentence, send a file pointer rather than inlining:

```
/is s implementer1 --file specs/parser.md   # receiver reads the whole file
```

Inline messages are capped (~400 chars in the notification); the file pointer
has no such limit and is the right tool for specs, diffs, and task lists.

### Keeping a session working: `/goal` and `/loop`

Two built-in slash commands turn a session from one-shot into autonomous.

**`/goal <condition>`** keeps a session working across turns until a stated
condition holds. After each turn a fast model checks the transcript against the
condition; if it is not met, the session takes another turn with the evaluator's
reason as guidance, and it clears itself when the condition is satisfied.

```
/goal all tests under tests/parser pass and `make lint` is clean
```

This is the workhorse for an implementer or tester: state the acceptance
criterion once and let the session iterate to it. The orchestrator can set its
own `/goal` to the overall acceptance criteria so it keeps driving the team
until the whole feature is done.

**`/loop [interval] <prompt>`** runs a prompt on a schedule while the session
stays open. With an interval (`/loop 5m ...`) it fires on a fixed cadence; with
no interval it self-paces between one minute and one hour based on what it
observes. Press Esc during the wait to stop.

```
/loop 10m re-run the full suite and report any new failures over /is
```

Use `/loop` for periodic checks (a tester re-running a suite, the orchestrator
polling progress) and `/goal` for "drive to a finish line". A role waiting for
the next instruction needs neither: the `/is` monitor wakes the session on an
incoming message, so an idle worker simply waits without polling or burning
tokens.

### A run, end to end

1. The user opens the orchestrator session in this directory and states the
   goal (or points it at a goal file in [`goals/`](./goals)).
2. The orchestrator reads the goal, decides the team, and (optionally) sends the
   analyst and architect in first to produce requirements and a design before
   any code is written.
3. The orchestrator launches the implementers, testers, and any other roles, one
   bus name each (see [Launching the team](#launching-the-team)).
4. Work is assigned over the bus, usually as file pointers to per-unit task
   specs. Implementer and tester run as an iterating pair (the
   implementer/reviewer loop the `/is` docs describe), each holding its own
   growing context.
5. The orchestrator integrates finished units, asks the reviewer for an
   independent correctness pass, and has deployment release and verify.
6. The orchestrator reports the result to the user and tears the team down with
   `bin/stop-team.sh`.

## Launching the team

The honest answer to "how does the orchestrator start the other sessions" is
that each role is a real Claude Code process, and something has to start that
process. There are four ways, from most to least hands-on. The recommended
local option is the tmux launcher: it lets the orchestrator spawn its own team
from a Bash call, with no manual tab-opening.

### 1. tmux launcher (recommended for local work)

Run the whole team inside tmux. The orchestrator lives in one window; the
[`bin/launch-team.sh`](./bin/launch-team.sh) script opens a sibling window per
role, each running `claude` seeded with an initial prompt that joins the bus,
reads its role file and the goal, and reports ready. Because the orchestrator
can run the script through its own `Bash` tool, it spawns the team itself:

```bash
# from inside a tmux session, in this directory:
bin/launch-team.sh goals/checkout-bug.md architect implementer1 tester1
```

Each role appears as a tmux window you can switch to and watch (or type into to
intervene). The script starts sessions with `--dangerously-skip-permissions` so
they run without prompts, and assigns a model per role to manage cost. Sessions
are **interactive, not `-p`**: a `-p` (print) session exits after one response,
which would kill a long-lived worker; an interactive session persists, and its
`/is` monitor keeps it alive between messages.

If you are not inside tmux, the script creates a detached session named
`orchestrator-team`; attach with `tmux attach -t orchestrator-team`.

See [Project layout](#project-layout-and-relaunching-with-a-new-goal) for how
the launcher finds role prompts and goals.

### 2. Manual terminal tabs or panes

The lowest-tech option, and the fallback when tmux is not in use. The
orchestrator prints the exact commands and the user opens a WSL terminal tab (or
tmux pane) per role:

```bash
cd ~/projects/claude-orchestrator
claude --dangerously-skip-permissions
# then, in the session:
/is c tester2
# read roles/tester.md and the goal, then tell the orchestrator you are ready
```

More typing, but nothing to trust beyond the commands you can see.

### 3. Agent teams (experimental, built-in)

Claude Code has an experimental [agent teams](https://code.claude.com/docs/en/agent-teams)
feature: enable it with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, then describe
the team in natural language and the lead session spawns teammates that share a
task list and message each other by name. It overlaps with this pattern and may
eventually replace the launcher for same-machine work. Current limitations make
it a weaker fit for long-running roles: no session resumption with in-process
teammates, one team per lead, no nested teams, and task status can lag. Worth
tracking; not yet the default here.

### 4. Cloud routines (remote, unattended, separate quota)

For work that should run unattended, on a schedule, or off your local machine,
Claude Code [routines](https://code.claude.com/docs/en/routines) run a saved
configuration (prompt, repos, connectors, triggers) in Anthropic's cloud.
Triggers are cron-like schedules, a per-routine API endpoint, or GitHub events.
Create them at the routines UI or with the `/schedule` skill. Good for a nightly
test run, a deploy-on-merge step, or offloading a self-contained role; not for
the tight interactive loop the core team runs in.

#### Which to use

- Interactive, you want to watch and intervene, same machine: **tmux launcher**.
- No tmux, or maximum transparency: **manual tabs**.
- Same-machine team and you want to try the built-in path: **agent teams**.
- Scheduled, event-driven, or off-machine: **cloud routines**.

## Project layout and relaunching with a new goal

The point of saving the pattern as files is that a new run is one command, not a
re-derivation. Nothing about a specific goal lives in the role prompts.

```
claude-orchestrator/
├── README.md            # this file
├── CLAUDE.md            # working agreement; read by every role
├── roles/               # one prompt per role; reused across all goals
│   ├── orchestrator.md
│   ├── analyst.md
│   ├── architect.md
│   ├── implementer.md
│   ├── tester.md
│   ├── reviewer.md
│   ├── devops.md
│   └── deployment.md
├── goals/               # one file per feature; the only thing that changes
│   └── _TEMPLATE.md
├── bin/
│   ├── launch-team.sh   # spawn the team in tmux
│   ├── stop-team.sh     # tear the team down
│   └── new-goal.sh      # scaffold a goal brief from the template
└── .team/               # transient: per-role launch prompts + active-team record

```

Two mechanisms make every session a competent teammate without a long launch
prompt:

1. **The working agreement reaches every role.** In greenfield mode the session
   runs in the clone and auto-loads `CLAUDE.md`; in `--workdir` mode it runs in
   the target tree (auto-loading *that* project's `CLAUDE.md`) and reads the
   orchestrator's `CLAUDE.md` by absolute path from the launch prompt. Either
   way the shared standards (verify, surgical changes, report over the bus)
   apply.
2. **The role file is read at launch.** The initial prompt points the session at
   `roles/<role>.md` (by absolute path), which holds that role's remit,
   boundaries, and definition of done.

To run a new goal: scaffold a brief, fill it in, then launch.

```bash
bin/new-goal.sh my-feature           # creates goals/my-feature.md from template
$EDITOR goals/my-feature.md
bin/launch-team.sh goals/my-feature.md analyst architect implementer1 tester1
# ... when done:
bin/stop-team.sh
```

The goal file (and the `--workdir` you point at) is the entire per-run state.
The role prompts and the working agreement are constant across every project the
template is cloned into.

## Engineering standards (the working agreement)

The pattern is only worth using if it produces correct work. These standards are
binding on every role; the tight version is in [`CLAUDE.md`](./CLAUDE.md) so it
loads into every session automatically.

- **Verify, do not guess.** Every load-bearing claim traces to something
  observed: a file read, a command run, a test reproduced. "It probably handles
  that" is not a finding. The cost of one check is almost always lower than the
  cost of acting on a wrong assumption.
- **Small, surgical changes.** Touch only what the assigned unit requires. Do
  not reformat, rename, or "improve" unrelated code. A diff that changes one
  thing is reviewable; a diff that changes ten is not.
- **Test with the real tools.** Run the actual suite. For a web change, drive a
  real browser with the
  [chrome-devtools MCP](../chrome-devtools-mcp). For binary output, compare bytes
  (`cmp`, `diff`), not impressions. A change is not done until it has been seen
  to work, not argued to work.
- **Finish what was assigned, or say what is left.** No silent partial
  completion. A role that cannot finish reports `status:` with the blocker and
  what it would need, rather than declaring victory on the easy part.
- **Stay in your lane.** An implementer does not redesign; the architect does
  not write the final code; the tester does not patch the implementation to make
  a test pass. Cross-cutting decisions go back to the orchestrator.
- **Report state honestly over the bus.** `done:` means done and verified.
  `status:` for progress. `question:` before anything destructive or ambiguous.
  The orchestrator's picture of the team is only as good as these reports.

These restate, for a portable repo, the discipline a careful engineer applies by
default. A session that also has the user's global instructions inherits the same
rules from there.

### Scripts over judgement

Where a task is deterministic, rule-based, and fast, write a script and call it;
do not spend an LLM turn on it. An LLM step is slower, costs tokens, and is
probabilistic, so it can get a mechanical task subtly wrong in a way a script
never will. Reserve LLM cycles for the genuinely open-ended work: design, code,
debugging, review, judgement calls. Everything around that, the plumbing, should
be deterministic.

This pattern follows its own rule. The mechanical parts are scripts under
[`bin/`](./bin), not instructions the orchestrator improvises each time:

| Script | Does, deterministically |
| :-- | :-- |
| `launch-team.sh` | Spawns the team, validates every bus name up front, maps roles to prompt files, assigns models, propagates the bus port. |
| `stop-team.sh` | Tears the team down exactly, by killing the recorded tmux windows/session. |
| `new-goal.sh` | Scaffolds a new goal brief from the template. |

When you extend the pattern, ask first whether a script can own the task before
reaching for an LLM step. Validation, file moves, formatting, parsing, spawn and
teardown, status checks, and preflight gates are script work. The orchestrator
calls these through its Bash tool; it does not reimplement them in prose.

## Tools and permissions

Roles are expected to use, and install, the tools they need. With sessions
started under `--dangerously-skip-permissions` (see below), a role can install a
package, add an MCP server, or run a build without stopping to ask, in the same
trusted local environment the user already works in.

- **DevOps owns the environment.** Missing a tool, a runtime, a service?
  DevOps installs and configures it, then tells the team it is ready, rather than
  every role solving setup independently.
- **MCP servers are available to every session.** Browser automation
  (chrome-devtools), image generation, and the other configured servers are
  there for the roles that need them; the tester uses the browser, the writer
  uses what it needs.
- **Prefer a dedicated tool over a shell hack.** It is the same instruction the
  global config gives: reach for the file and search tools, the browser MCP, the
  diff tools, before improvising in Bash.

## Running unattended (cost, permissions, rate limits)

The team is meant to run with as little babysitting as the work allows. Three
things otherwise interrupt a long autonomous run.

### Permissions

Start sessions with `--dangerously-skip-permissions` (equivalent to
`--permission-mode bypassPermissions`) so no role stops on a permission prompt.
This skips all prompts except a hard circuit breaker on catastrophic paths
(`rm -rf /`, `rm -rf ~`). Only do this in a trusted local environment, which is
the assumption this whole pattern makes. The launcher uses the flag by default.

If you want a tighter posture, pre-approve the commands the team needs in
`.claude/settings.json` (`permissions.allow`) and run a narrower
`--permission-mode` instead; the tradeoff is the occasional prompt when a role
reaches for something unlisted.

### Cost

Concurrent sessions all draw on the same subscription limit, and Anthropic
tokens are expensive. Levers, in rough order of effect:

- **Right-size the team.** Fewer roles, fewer tokens. Do not launch a deployment
  session for a goal with nothing to deploy.
- **Pick the model by where the work runs.** Local subscription sessions and
  remote API-paid agents have opposite cost shapes, so they get opposite
  defaults:
  - **Local (CLI, subscription):** err toward the best model. The launcher runs
    every role on Opus by default; drop a role to a faster model only when you
    want speed over depth on that role (uncomment the override in `model_for()`).
  - **Remote (cloud routines, API-paid):** be cost-conscious. Run the bulk of
    the work on Sonnet, but always have an Opus session check the result; cheap
    tokens that ship a wrong change are not cheap.
  - Current ids: `opus` (`claude-opus-4-7`), `sonnet` (`claude-sonnet-4-6`),
    `haiku` (`claude-haiku-4-5`). Tune `model_for()` in
    [`bin/launch-team.sh`](./bin/launch-team.sh).
- **Offload to cloud routines** for self-contained, schedulable work, which run
  on separate infrastructure (and where the cost-conscious split above applies).
- **Let idle roles idle.** A waiting `/is` session costs nothing until a message
  arrives; do not keep roles busy-looping.

### Rate limits

Claude Code already retries transient failures (429 throttles, 529 overload,
timeouts) up to ten times with exponential backoff, showing a
`Retrying in Ns` countdown, so brief limits self-heal. For long runs you can
harden this:

- `CLAUDE_CODE_MAX_RETRIES=40` raises the retry budget from the default 10.
- `API_TIMEOUT_MS=900000` lengthens the per-request timeout (default 600000).
- On a sustained 429, reduce concurrency: lower
  `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`, fold a role back into the
  orchestrator, or move a role to a smaller model with `/model`.
- A 529 (overload) is capacity across all users, not your quota; switching model
  with `/model` can route around it since capacity is tracked per model.

A practical pattern under tight limits: stagger session starts a few seconds
apart rather than launching the whole team at once, and have the orchestrator
serialise the heaviest roles instead of running them in parallel.

## Design questions, answered

The questions that motivated this repo, with where each is handled.

- **How does the orchestrator launch role sessions locally?** Best local option
  is the [tmux launcher](#launching-the-team), driven by the orchestrator's own
  Bash tool; manual tabs are the fallback; agent teams and cloud routines are
  alternatives. See [Launching the team](#launching-the-team).
- **How are the prompts saved so the project relaunches with a new goal?** Role
  prompts in [`roles/`](./roles) and the working agreement in
  [`CLAUDE.md`](./CLAUDE.md) are constant; only a [`goals/`](./goals) brief
  changes per run. See [Project layout](#project-layout-and-relaunching-with-a-new-goal).
- **How is the work kept excellent?** The
  [engineering standards](#engineering-standards-the-working-agreement) bind
  every role: verify, surgical changes, test with real tools, no silent partial
  work, an independent reviewer pass.
- **How does it use and install tools?** See
  [Tools and permissions](#tools-and-permissions): DevOps owns setup, every
  session can use the MCP servers, bypass-permissions removes the friction.
- **How are ask-the-user dialogues, permission prompts, and rate limits kept out
  of the way?** See
  [Running unattended](#running-unattended-cost-permissions-rate-limits):
  bypass-permissions, retry tuning, model tiering, staggered starts.

## Open questions and future work

Patterns that still need testing in practice, and known gaps.

- **Team composition heuristics.** When is two implementers right versus one?
  When does a separate reviewer earn its cost over the tester doing both? These
  want real runs to settle, not a priori rules.
- **Integration discipline.** With several implementers touching one tree,
  who merges, and how are conflicting edits serialised? The current answer is
  "the orchestrator owns integration"; the mechanics need refining.
- **Handoff format.** File-pointer task specs work, but a stable schema for a
  task brief (inputs, acceptance criteria, files in scope, files off-limits)
  would make handoffs cleaner and reviews sharper.
- **Running several teams at once.** The `/is` bus is one port with a flat name
  registry, so two teams launched naively both claim `orchestrator`,
  `implementer1`, and collide. Today you can isolate a team by giving it its own
  bus: export `INTER_SESSION_PORT` (a distinct port per team) in the orchestrator
  session, and the launcher propagates it to the spawned roles, so each team runs
  on its own bus. That is a workaround, not a model: it burns a port per team and
  the names still collide if two teams share a port. The clean fix is native
  namespacing in `/is`, a team id or logical channel within one bus (or a
  separate connection type per team), so several teams coexist without
  port juggling. Future work on the inter-session project.
- **`/is` across machines.** The bus is currently a localhost Unix-socket /
  WebSocket design, single machine only. Extending it over TCP would let a team
  span hosts (a heavy build box, a separate test runner). That is on the
  inter-session project's roadmap, and pairs naturally with the namespacing above.
- **`/is` security for multi-machine.** The current model is deliberately lax:
  any process running as the same Unix user can connect, which is fine for one
  user on one machine. A TCP bus crosses a trust boundary and would need real
  authentication, transport encryption, and per-peer authorization before it is
  safe to expose beyond localhost.
- **Cost ceiling.** A multi-session team on a subscription plan can exhaust the
  shared limit quickly. A clearer policy on what runs locally versus on cloud
  routines (separate quota) would make heavy runs predictable.

## See also

- [`../claude-code-inter-session`](../claude-code-inter-session): the `/is`
  message bus this pattern is built on.
- [Agent teams](https://code.claude.com/docs/en/agent-teams),
  [routines](https://code.claude.com/docs/en/routines),
  [`/goal`](https://code.claude.com/docs/en/goal),
  [scheduled tasks / `/loop`](https://code.claude.com/docs/en/scheduled-tasks),
  [headless mode](https://code.claude.com/docs/en/headless),
  [permissions](https://code.claude.com/docs/en/permissions): the Claude Code
  features this pattern composes.

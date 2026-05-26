# Native Claude Code agents vs. this orchestrator

Comparison of this project against Claude Code's built-in multi-agent primitives.
Written 2026-05-25 against Claude Code ~v2.1.150, Opus 4.7. Supersedes the
prior-art notes in [BACKLOG.md](../BACKLOG.md) where they differ; verify version-
sensitive details (experimental flags, prices) before relying on them.

## The category distinction (read this first)

These are not three points on one axis. They are three layers, and the project
already uses the first internally.

- **Subagents** are a *worker primitive*: a helper spawned inside one session,
  own context window, one-shot (prompt in, summary out), reports only to its
  caller. The orchestrator uses these inside a role for fan-out (search,
  analysis). They are not a competitor to the orchestrator; they are a tool it
  calls.
- **Agent Teams** (first-party, experimental) are the *real head-to-head*: a lead
  session plus peer teammates, each its own context window, a shared task list,
  and direct teammate-to-teammate messaging. This is Anthropic's build of the
  exact pattern this project implements.
- **This orchestrator** is a *coordination + governance system*: persistent role
  sessions over the `/is` bus, an enforced verify/scope gate layer, a readable
  ledger, a dedicated integrator, per-run isolation, and a rate-limit watchdog.

So the honest framing: subagents are the cheap split inside a session; the
orchestrator and Agent Teams compete for the multi-session coordination job.

## What changed since the project's premises were set

**Models got bigger and ~3x cheaper.** Opus went from $15/$75 per MTok (4.1) to
$5/$25 (4.5 through 4.7, current). Sonnet 4.6 is $3/$15, Haiku 4.5 is $1/$5.
The **1M-token context window is now standard-priced** for Opus 4.7/4.6 and
Sonnet 4.6, no premium above 200K. Cache reads are 0.1x input. (Caveat: Opus 4.7
uses a new tokenizer that can spend up to ~35% more tokens on the same text, so
the per-token win is partly eaten on token count.)

**Consequence for the "why a team" rationale.** The project's stated reason for
splitting work, "a single long session degrades as context fills," is weaker
than when it was written: a 1M-priced-flat window holds far more before it
matters, and auto-compaction extends a single session further. The surviving
justifications for multi-session are narrower and should be stated as such:
1. **Parallelism** for wall-clock speed (one session is serial).
2. **Fault isolation** (one role's bad turn does not poison the others' context).
3. **Enforced governance + audit trail** (gates, ledger, decision-log).
4. **Persistence and resume** across restarts.
5. **Topic-agnostic substrate** (legal, docs pipelines, not only code).
"Context fills up" is no longer the lead argument; cost and parallelism are.

**Agent Teams matured.** Since the BACKLOG's 2026-05-24 note it gained the pieces
that used to be this project's differentiators (see below): quality-gate hooks,
a dependency-aware shared task list, plan approval, and subagent-definition reuse.

## Cost (the axis that is easy to underweight)

Parallelism multiplies spend linearly. Public guidance (CloudZero, 2026): ~$13/day
for one session, ~$30-40/day at 3 agents, ~$50-130/day at 5-10. A Pro plan's
window drains in under an hour at 5 parallel agents; sustained multi-agent use
wants Max 5x/20x or API billing.

- **Subagents** are the cheapest split: results are summarized back into one
  context, no inter-agent traffic.
- **Agent Teams / this orchestrator** are the expensive end: every teammate is a
  full instance, and on Agent Teams every inter-agent message is a billable model
  round trip. The cost docs put Agent Teams at "approximately 7x more tokens than
  standard sessions when teammates run in plan mode." The orchestrator's `/is` bus
  has the same per-instance multiplier, with one real lever the others lack: an
  **idle role on the bus costs nothing** (the monitor holds it open with no API
  call), so a paused-not-retired role is free. Agent Teams is the opposite: its
  cost docs warn "active teammates continue consuming tokens even if idle. Clean
  up teams when work is done."

Model-tiering is the main control on both: bulk on Sonnet/Haiku, Opus to check.
The project already advises this (`model_for()` in `bin/lib/team-spawn.sh`).

## Subagents: pros / cons

Pros: zero infrastructure (a markdown file in `.claude/agents/`); automatic
delegation by `description`, or `@`-mention; clean per-task context isolation
(exploration never pollutes the parent); declarative per-agent `tools`/`model`/
MCP/hooks; optional cross-session `memory:` scopes (user/project/local);
trivial parallel fan-out (foreground or `background: true`); maintained upstream.

Cons: no peer-to-peer messaging (report to caller only); no nesting (a subagent
cannot spawn subagents); ephemeral by default (resume needs the agent-teams flag
+ `SendMessage`); every returned summary consumes the parent's context, so wide
fan-out can exhaust the orchestrating window; one parent is a single throttle
point (no watchdog); no enforced verify/scope gate; no team lifecycle. Note:
`memory:` and forked subagents (`CLAUDE_CODE_FORK_SUBAGENT=1`, inherits parent
context) soften the "stateless/blind" cons but are partial/experimental.

## Agent Teams: pros / cons

Pros: first-party and maintained; lead + peer teammates each with own context;
**Mailbox** auto-delivers messages, no polling; **shared task list** with
automatic dependency unblocking and file-locked claiming (better task
coordination than a hand-maintained markdown ledger); **plan-approval mode** (a
built-in review gate); **quality-gate hooks** `TaskCreated`/`TaskCompleted`/
`TeammateIdle`, each blockable with exit 2 (the primitive to build verify/scope
gates on); **subagent-definition reuse** (define a role once, use as subagent or
teammate); in-process mode runs in any terminal (split panes need tmux/iTerm2).

Cons (experimental, from the docs' own limitations): **no session resumption**
with in-process teammates (`/resume` does not restore them); **one team at a
time** per lead; **no nested teams**; lead is fixed for the team's life;
permissions set at spawn (all teammates inherit the lead, including
`--dangerously-skip-permissions`, no per-teammate mode at spawn); task status can
lag and block dependents; no built-in merge/integrator role (guidance is just
"each teammate owns different files"); no enforced scope/off-limits diff check;
no rate-limit auto-recovery; significantly higher token cost than one session.

## Agent Teams: billing and four common myths (verified 2026-05-25)

Two different Anthropic multi-agent products are easy to conflate; cons attributed
to "agent teams" usually belong to the cloud one.

- **Agent Teams** (local): runs in Claude Code on your machine, on a **Pro / Max /
  Team / Enterprise subscription or an API key**, native local files, loads your
  local project/user MCP + skills. This is the fair comparison to this project.
- **Managed Agents** (cloud): runs in Anthropic's cloud, API/platform-billed,
  container FS (code must be synced there), cloud connectors. A different product.

Four claims, all checked against *local* Agent Teams:

| Claim | Verdict |
| :-- | :-- |
| "Needs an API key" | False. Runs on your subscription. (API-key-only applies to the Agent SDK before its 2026-06-15 subscription credit, and to cloud Managed Agents.) |
| "Bypass perms = more freedom" | Available in both: teammates inherit the lead's mode, including `--dangerously-skip-permissions`. The orchestrator edge is *granularity* (per-role settings/worktree), not raw bypass. |
| "Local files, no upload" | Both have native local FS. Not an Agent Teams con (it is a Managed Agents con). |
| "My MCP servers / skills" | Teammates load local project/user MCP + skills like any session. Caveat: a subagent definition's `mcpServers`/`skills` frontmatter is ignored when it runs as a teammate. |

So billing, local files, MCP, and bypass are **equal** against local Agent Teams.
The orchestrator's defensible edge is the discipline + lifecycle layer (gates,
audit ledger, integrator/scope, resume, multi-team, watchdog, free idle roles),
not the substrate.

## This orchestrator: pros / cons

Pros: **persistent, revisitable roles** whose accumulating context is the product;
**enforced discipline layer**, `verify-unit.sh` (fresh exit-0 log required before
`done:`) + `check-scope.sh` (off-limits diff check vs. a per-unit baseline) + a
pluggable `bin/gates/` library for non-code work; **human-readable ledger +
decision-log** that survives compaction and is an audit trail; **dedicated
integrator** + worktree-per-unit so merge never touches the orchestrator's
context; **multiple concurrent teams** via `TEAM_RUN_ID` isolation (Agent Teams
allows one); **api-watchdog** auto-recovers rate-limit stalls with backoff +
ntfy; **dynamic scaling** with a hard cap, work-loss protection, and `/proc`
ownership proof; **free idle roles**; **topic-agnostic** (invents roles from a
template, runs non-code pipelines).

Cons: **heavy** (bus + tmux + launchers + conventions vs. a markdown file);
**external dependency** on the sibling `/is` project; **localhost-only,
single-machine, unauthenticated** bus; **tmux-required** (Agent Teams in-process
needs no tmux); **manual orchestration** (a session actively assigns and gates,
no auto-delegation); **`--dangerously-skip-permissions` everywhere**, defended
only by a best-effort deny-list; **higher cost** without deliberate tiering;
**bespoke substrate to maintain** against fast-moving first-party features.

## The moat, honestly

What this project still has that Agent Teams does not, verified against the Agent
Teams docs' limitations as of 2026-05-25:
1. **Built-and-wired enforced gates** (verify + scope) and a non-code gate
   library. Agent Teams has the *hook primitive* (`TaskCompleted` exit 2) but you
   would write the gates yourself.
2. **A readable narrative ledger + decision-log** as an audit artifact. Agent
   Teams stores task state as JSON, not a why-log.
3. **Dedicated integrator + scope/off-limits diff enforcement.** Agent Teams has
   no merge role and no scope check.
4. **Session resume and multiple concurrent teams.** Agent Teams resumes neither
   in-process teammates nor more than one team per lead.
5. **Rate-limit auto-recovery** (api-watchdog).

The distinction that matters: these are now "built and wired, auditable, multi-
team, resumable," not "impossible elsewhere." The substrate (sessions, messaging,
task list, scheduling, remote) has converged with first-party primitives, and
Agent Teams' new hook surface makes the *discipline layer itself portable* onto
it. The strategic read the project already holds is now more actionable: re-target
the gates + ledger + integrator as a governance layer on Agent Teams hooks once
Agent Teams leaves experimental, rather than maintaining the bespoke bus. Not an
immediate rewrite, Agent Teams is still experimental (no resume, one team at a
time), so the substrate keeps real advantages today.

## When to use which

| Situation | Reach for |
| :-- | :-- |
| Short focused side task whose result fits back in context (search, one-off analysis, a review pass) | Subagent |
| Cost-routing verbose work to a cheaper model with tool restrictions | Subagent |
| Auto-delegation with no hand-wired handoff | Subagent |
| Self-contained parallel burst, peers that discuss/challenge, no resume needed | Agent Teams |
| Cross-layer feature where each teammate owns a slice, one sitting | Agent Teams |
| Work that must pass an enforced verify + scope gate before it counts as done | This orchestrator |
| Long-lived roles whose accumulating context is the deliverable; resume across restarts | This orchestrator |
| Unattended multi-round runs needing watchdog, isolation, kill-switches, audit ledger | This orchestrator |
| Multiple teams running at once in one clone | This orchestrator |
| Non-code substrate (legal, docs pipelines) with custom gates | This orchestrator |

## Sources

- Pricing: <https://platform.claude.com/docs/en/about-claude/pricing> (2026-05-25)
- Agent Teams: <https://code.claude.com/docs/en/agent-teams>
- Subagents: <https://code.claude.com/docs/en/sub-agents>
- Agent team token cost + idle-token warning: <https://code.claude.com/docs/en/costs>
- Subscription billing for Claude Code: <https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan>
- Agent SDK subscription credit (2026-06-15): <https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan>
- Cost of parallel sessions: <https://www.cloudzero.com/blog/claude-code-agents/>

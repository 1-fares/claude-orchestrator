# Backlog

Forward-looking work items, last updated 2026-05-27. Not yet scheduled. B3 is
discussion-only for now (no changes until agreed). Prior-art research precedes
build on all of them: adopt or integrate mature existing tools rather than
reinvent. **B9 (dynamic team scaling) is the priority next build per the operator
(2026-05-25); design + policy resolved below.** **B12 (2026-06-15 Agent SDK
credit pool) is a time-bound prep item added 2026-05-27.**

---

## B12 - Exploit the 2026-06-15 Agent SDK credit pool

**Status: research done, prep work pending.** Time-bound: the new credit pool
opens on 2026-06-15. Eligible users must claim it once through their Claude
account; it then refreshes monthly with the billing cycle and does not roll over.

**The finding (verified 2026-05-27).** Anthropic is splitting subscription
billing into two buckets on 2026-06-15. Verbatim from the help-centre article:

> Starting June 15, 2026, Claude Agent SDK and `claude -p` usage no longer
> counts toward your Claude plan's usage limits. Your subscription usage limits
> stay the same and stay reserved for interactive use of Claude Code, Claude
> Cowork, and Claude.

The new pool covers Agent SDK calls (Python/TS) in your own projects, `claude -p`
non-interactive mode, the Claude Code GitHub Actions integration, and
third-party apps that authenticate with a Claude subscription (Zed, OpenClaw,
etc.). It does **not** cover interactive Claude Code, Claude.ai web/desktop,
Cowork, or features that draw from usage credits.

Per-tier monthly credit: Pro $20, Max 5x $100, **Max 20x $200**, Team Standard
$20, Team Premium $100, Enterprise usage-based $20, Enterprise Premium $200.
Operator is on Max 20x, so the available walled-off SDK budget is $200/month
(at standard API rates), additive on top of the existing interactive
subscription usage. Overage falls through to usage credits (the prepaid
balance enabled at `claude.ai → Settings → Usage`) at standard API rates, or
fails outright if usage credits are not enabled. Per-user (not pooled across a
team), no rollover.

**Why this matters here.** Today the orchestrator spawns role sessions as
ordinary subscription-authenticated `claude` processes (`bin/lib/team-spawn.sh`).
Every role's tokens draw from the same interactive Max 20x pool the operator
also uses by hand for Claude Code and Claude.ai. After 2026-06-15 there is a
second, walled-off $200/month pool for programmatic and SDK-authenticated work
that is *not* available to the existing role launch path. Routing eligible
work onto that pool is free headroom: roughly $200/month of API-priced
inference per user that would otherwise either eat into the interactive quota
or never be spent at all (the credit does not roll over).

**Concrete prep work to evaluate, in order of bluntness.**

1. **Identify which roles or sub-tasks are pool-eligible.** The pool only
   accepts Agent SDK calls and `claude -p` (non-interactive). Interactive
   `claude` sessions in tmux do not qualify. So the candidates are: (a) any
   role whose run can be reframed as a non-interactive `claude -p` invocation
   with the prompt fed on stdin/file, (b) any deterministic batch job that the
   orchestrator currently shells out for (verifier output summarisation,
   triage of bus messages, scope-check explanations, structured ledger
   updates, etc.) which could be a `claude -p` or short SDK call, (c) gate
   helpers (`bin/gates/llm-judge`, `rubric-judge`, `cite-support`) that are
   already one-shot LLM calls.
2. **Route those calls via subscription-authenticated SDK / `claude -p`.**
   Switch the eligible call sites to authenticate against the Max 20x
   subscription (the default for `claude` on the operator's machine) rather
   than against a Console API key, so they draw from the new $200 pool. For
   any call site that already exists as Anthropic Messages API code under a
   Console key, evaluate whether moving to subscription-auth SDK is a net win
   given the per-user cap, latency, and observability tradeoffs.
3. **Cap detection and graceful fallback.** When the $200 monthly pool runs
   out the SDK either falls back to usage credits (prepaid, billable) or
   fails. Decide which we want for the orchestrator: fail fast (cost-safe but
   may stall a run mid-flight) or fall through to usage credits with a hard
   monthly ceiling configured in `claude.ai → Settings → Usage`. Document in
   the role files and STATUS.md.
4. **One-time claim.** Operator must claim the credit through their Claude
   account on or after 2026-06-15. Note in the runbook; failing to claim
   means $0 in the pool that month.
5. **Multi-user / shared-machine note.** The credit is per Claude account,
   not pooled. If the orchestrator pattern is ever run by another user on a
   different subscription, each user has their own $200; the credits do not
   sum across accounts.

**What this does NOT touch.**

- Claude Managed Agents. That product authenticates with a Console API key,
  bills against the Console balance (tokens at standard rates + $0.08 per
  session-hour of `running` time), and is unaffected by the 2026-06-15 change.
  If we ever adopt Managed Agents for cloud-side role execution (the B2
  direction noted in the cross-cutting findings), that is a separate funding
  decision against the Console balance, not against the new SDK pool.
- Interactive Claude Code role sessions. They keep drawing from the
  subscription's interactive pool as today.
- Background sessions (`claude --bg`, `claude agents`). They are local,
  subscription-authenticated, and count as interactive use for billing
  purposes; not eligible for the new pool.

**Sources verified 2026-05-27.**

- [Use the Claude Agent SDK with your Claude plan (Anthropic help centre)](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Manage usage credits for paid Claude plans](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans)
- [What is the Max plan?](https://support.claude.com/en/articles/11049741-what-is-the-max-plan) (confirms Max 20x = $200/month web; no $300 tier)
- [Claude API pricing, Managed Agents section](https://platform.claude.com/docs/en/about-claude/pricing) (Managed Agents = $0.08/session-hour + tokens, API-billed)
- [Claude Managed Agents overview](https://platform.claude.com/docs/en/managed-agents/overview) (requires Claude API key)
- [InfoWorld: Anthropic puts Claude agents on a meter across its subscriptions](https://www.infoworld.com/article/4171274/anthropic-puts-claude-agents-on-a-meter-across-its-subscriptions.html)

---

## B9 - Dynamic team scaling (grow/shrink the team mid-run)  [BUILT 2026-05-25]

**Status: built.** `bin/add-role.sh`, `bin/retire-role.sh`, the shared
`bin/lib/team-spawn.sh` + `bin/lib/roster.sh`, the idempotent api-watchdog start,
the orchestrator "Dynamic team management" section, and the ledger `## roster`
section are all implemented and tested (see STATUS.md). The original design and
policy notes below are retained for the rationale.

**What.** Let the orchestrator change team composition as work progresses: spawn
a specialist when a clear skill gap appears mid-run (a researcher, a second
front-end dev, an ETL specialist, an Azure DevOps engineer, ...) and retire a
role whose job is complete and won't recur. Bounded, justified, never runaway.

**Why.** Today the team is fixed at the READY gate and launched once. Real work
reveals needs that were not visible up front (an implementer hits an ETL problem
it is not equipped for; a unit blocks waiting on expertise; independent work
appears that a second same-role would parallelise). The orchestrator should
adapt the roster instead of forcing the work into an ill-fitting role or
stalling.

**Resolved policy (operator decisions 2026-05-25).**
- **Authority: auto within a cap, surface every change.** The orchestrator adds
  and retires freely up to `MAX_TEAM_SIZE`, logs the why to the decision-log, and
  emits a one-line `added X / retired Y (reason)` notice. Operator can veto after
  the fact.
- **Soft cap, operator-chosen at start (default 12).** `add-role.sh` refuses past
  it, forcing a retire-or-ask. The operator picks enforce-12 / a custom number /
  uncapped at orchestrator start; it lives in `$TEAM_DIR/max-team-size`
  (`MAX_TEAM_SIZE` env overrides for one call). The real backstop against runaway
  spawning when enforced.
- **Autonomous (B2): growth allowed unattended within the cap, with an ntfy push
  per roster change.** Pruning (pause/retire) also allowed unattended.

**Guardrails (the "don't go wild" part).**
1. Soft cap (operator-chosen at start: default 12, custom, or uncapped) enforced
   by `add-role.sh`.
2. Reuse-before-spawn: check whether an existing idle role with the right skill
   can take the work before creating a new one.
3. Justification logged: every add/retire writes a decision-log line (why +
   triggering unit). No silent roster churn.
4. Anti-flap hysteresis: do not retire then re-spawn the same base within a
   cooldown; no speculative "just in case" spawns.

**Pause vs retire (a deliberate distinction).** An idle role on the bus costs
nothing (the `/is` monitor holds it open with no API calls). So retire is NOT a
cost lever; its value is freeing a slot under the cap and keeping the roster
legible. Therefore: temporarily-idle role -> `pause:` (keeps accumulated context,
free, instant resume); done-forever role -> retire (terminal: kills the session,
frees the slot, loses context).

**What already exists (lowers the cost a lot).**
- `launch-team.sh` already adds a window to a LIVE session (`start_one`, the
  has-session branch) and deliberately preserves live `.team/active` entries so a
  second launch adds rather than replaces (the reap-dead-keep-live block).
- `stop-team.sh` already has the clean per-role kill pattern to reuse for a
  single-role retire: graceful send-keys -> TERM process group -> KILL -> close
  window -> verify against `active`.
- The api-watchdog re-scans `list-windows` each tick, so a newly added role is
  covered automatically.
- B5 auto-authoring (`ensure_role_file` from `_TEMPLATE.md`) already concocts a
  tailored role file for a novel skill.

**To build.**
1. `bin/add-role.sh [--workdir DIR] <goal> <role> [--task <brief>]`: spawn ONE
   role into the live session (factor/reuse `start_one`). Refuse if already live;
   optional auto-numbering; enforce `MAX_TEAM_SIZE`; decision-log line; (B2) ntfy.
2. `bin/retire-role.sh <role> [--reason ...] [--force]`: graceful single-role
   teardown scoped to that one `active` entry; archive `health/`+audit to
   `$TEAM_DIR/retired/`; refuse if the role has in-flight units unless `--force`
   (which first files the remaining work as a `todo` unit); decision-log line.
3. Fix: make `launch-team.sh`'s api-watchdog start idempotent (a repeated call
   currently starts a SECOND watchdog; guard on the pidfile's process being live).
4. `roles/orchestrator.md`: a "Dynamic team management" section (triggers,
   guardrails, reuse-before-spawn, pause-vs-retire, the cap, justification).
5. `templates/state.md`: a "team roster" section (current roles + status + when
   added/retired) so the roster survives orchestrator compaction.

**Safety.** `retire-role.sh` must reuse the cleanup/stop-team scoping discipline:
operate ONLY on this run's `TEAM_SESSION`, kill ONLY the target role's recorded
pid-group and window, verify it is still a claude process before killing, never
touch another session. (Same hard-won rules as `cleanup.sh`.)

**Depends on / strengthens.** Independent of B2 but strengthens it (autonomous
runs that can right-size their own team are far more capable). Reuses B8's ntfy
channel for the autonomous-mode change notices.

---

## B2 - First-class background / autonomous mode

**What.** A single command that scaffolds, launches, and runs a goal to
completion in the background, managing tmux and the bus itself, surfacing
decisions through notifications rather than a live pane. Includes a hardened
lifecycle: idempotent teardown, orphan and dangling-session reaping, bus-port
and process cleanup, crash recovery.

**Why.** Demonstrated feasible during testing (the harness drove
`start-orchestrator.sh` programmatically and monitored via the tmux pane and the
ledger). Productising it enables unattended runs and is the keystone for remote
use (B4).

**Scope / considerations.**
- Auto-approve or async-approve the READY gate; machine-checkable acceptance, a
  round budget, and a kill switch.
- Notification on done / blocked / needs-input (the `ntfy` push channel +
  `NTFY_URL` env are already wired by B8; reuse them).
- A watchdog for orphans; never leak tmux servers, bus servers, or pids across
  many runs. (Teardown was reliable in testing: every `reset.sh` killed the
  session, reaped the tree, and stopped the bus on its port.)
- Keep human gates as asynchronous (notify and wait), do not remove them: the
  orchestrator's clarifying questions were valuable in testing.

**What's already in place that lowers the cost.** Per-run `TEAM_RUN_ID` isolation
(parallel teams trivially), recovery-aware `bin/run.sh`, orphan-safe
`bin/cleanup.sh`, the `interactive | autonomous` mode is already a concept in
`roles/orchestrator.md`, the orchestrator can be driven programmatically
(proven during testing), and **B8** (`bin/api-watchdog.sh`) gives transient
rate-limit / network resilience plus a working ntfy push channel, which were
the two hard prerequisites for unattended runs.

**Proposed surface.** A single command:
```
bin/run.sh --auto "<goal>" [--accept "<exit-0 cmd>"] [--max-rounds N] [--notify <ntfy-url>]
```
Launches detached, returns the run-id, prints the attach command for later
(`TEAM_RUN_ID=<id> bin/attach.sh`). Reuses today's per-run isolation, so several
auto runs coexist.

**Notify-and-resolve UX (the operator's path back in).** When the orchestrator
hits a blocker:
1. It writes a per-run `$TEAM_DIR/PENDING.md` with the question + suggested
   answers + the exact resolution command.
2. It sends an `ntfy` push whose body is **enough by itself**: run-id, target,
   one-line question, and the literal `TEAM_RUN_ID=<id> bin/attach.sh` to paste.
3. A new helper `bin/inbox.sh` lists every run currently awaiting input (run-id,
   target, age, question, attach command), so a missed notification is
   recoverable.

**UX tiers (build in order).**
1. **MVP:** ntfy body has the question + attach command; operator opens any
   terminal, pastes the command, answers in-pane. `bin/inbox.sh` is the catch-up.
2. **Paired with B4:** the notification also includes an SSH-and-attach
   one-liner, so the operator can answer from a phone terminal app without
   thinking.
3. **Later:** reply-over-ntfy (or Telegram/Slack) so a notification button on
   the phone delivers the answer over the bus; no terminal needed.

**Hard rule.** Autonomous does NOT mean silent: the human gate is asynchronous,
not removed. The orchestrator's clarifying questions were valuable in testing;
notify and wait, do not silently decide.

**Safety.** Autonomous + `--dangerously-skip-permissions` is unattended code
execution; safety rests on the existing gates (verify, per-unit scope baseline,
branch isolation, integrator merging on `orch/...`) plus off-limits paths in the
brief plus `bin/panic.sh` as the kill switch. The cleanup side never auto-kills
(see `bin/cleanup.sh`).

**Depends on.** Strengthens and is strengthened by B4 (notification + reply
channels are mostly the same problem). Best designed together.

---

## B3 - Productise / open-source  (discussion only for now)

**What.** Make the project shippable to others. Remove any bundled non-English
(Chinese) text and attribute the original author of the `/is` bus in the README;
general cleanup; handle environments other users will have.

**Why.** `/is` is robust and effective and worth sharing; the orchestrator
pattern is reusable.

**Findings so far.** The local `~/.claude/skills/is` copy has no CJK text and no
attribution line. The Chinese text and original author are presumably in the
upstream project `/is` derives from. First sub-step: locate the upstream source
and its licence, add attribution, and confirm no bundled CJK remains.

**Scope / considerations.**
- README, LICENSE, attribution; licensing and attribution resolved before any
  public release.
- Portability beyond WSL/Linux: macOS, other shells, paths with spaces, missing
  dependencies (tmux, claude, uv, npm, python3); a dependency preflight with
  clear errors.
- The clone-per-project distribution model; running concurrent teams; resilience
  to Claude Code version changes.

**Depends on.** Stabilised by B1 and B2; benefits from B5's decoupling work.

---

## B4 - Remote / mobile control (primary path = /remote-control; escape-hatch helpers built)

**STATUS 2026-05-25: phone test ON HOLD until 2026-06-02.** Code is built and
verified locally. The `/remote-control` end-to-end phone test is blocked: the
operator switched Anthropic accounts for usage reasons and the rc-connected
account is unavailable until after 2026-06-02. Resume the Step 1-8 walkthrough
(README "Remote control from a phone") then.

**What.** Drive the system from a phone: one session running on the machine,
connect remotely, kick off and monitor builds and debugging.

**Decision (2026-05-25).** Use first-party **`/remote-control`** as the primary
path. Outbound-only, polished mobile app, push notifications when Claude needs
input, multi-session (server mode, up to 32), can attach to an already-running
session (`/remote-control` slash command). Zero host-side network setup.

**Built (2026-05-25), retained as escape hatch.** Not needed for the primary
path; useful when `/remote-control` cannot cover the case (shell access, role
window scrollback, custom watchdog action buttons, multi-run lifecycle).
- **Tier 1 helpers.** `bin/team-status.sh --mobile` (compact dashboard);
  `bin/inbox.sh` (every live run with run-id + attach/approve commands);
  `bin/approve.sh` (send `go` or any text to a run's orchestrator pane).
- **Tier 2 action-button hook.** `bin/notify-hook.py` (singleton HTTP daemon,
  stdlib only, HMAC-signed URLs, TTL); `bin/sign-action-url.sh`;
  `bin/notify-via-ntfy.sh`. OFF by default; start with
  `bin/notify-hook.py --bind <reachable-ip> --port 8421` if you decide you
  want it. Verified end to end (bad-sig 403, expired 403, valid 200 + correct
  send-keys).

**Gap that `/remote-control` does not cover.** The api-watchdog's stall /
recovery / give-up signals (B8) do not flow through it -- they only fire when
Claude itself decides input is needed. Keep both apps on the phone: the Claude
app for `/remote-control` + the ntfy app for watchdog pushes.

**Reaching the host for the escape hatch.** A tunnel (Tailscale, Cloudflare
Tunnel, anything) is needed only if you choose to use the helpers from the
phone. Not required for the primary path. If set up, point `NOTIFY_HOOK_BASE`
at the reachable IP and the signed-URL helper picks it up automatically.

---

## B10 - Evaluate Agent Teams features for folding into the orchestrator

**What.** Assess each first-party Agent Teams capability and decide, per feature,
whether to adopt it, mirror it, or skip it. Full comparison and evidence in
[docs/native-agents-comparison.md](docs/native-agents-comparison.md).

**Why.** Agent Teams (local, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`,
v2.1.32+) is the first-party build of this exact pattern and has matured since the
2026-05-24 prior-art note. The substrate has converged; our durable value is the
discipline layer (gates + ledger + integrator + scope). The strategic question is
whether to keep the bespoke `/is` substrate or re-target the discipline layer to
run on top of Agent Teams once it leaves experimental. Decide deliberately, not by
drift.

**Candidates to evaluate (adopt / mirror / skip).**
1. **Quality-gate hooks** (`TaskCompleted` / `TaskCreated` / `TeammateIdle`,
   exit 2 to block). This is the primitive our enforced gates need. Strategic:
   prototype `verify-unit.sh` + `check-scope.sh` as a `TaskCompleted` hook on an
   Agent Teams run; if it works, the discipline layer becomes portable and the
   `/is` substrate can eventually retire. Highest-leverage item.
2. **Shared task list** (auto dependency unblocking + file-locked claiming). Our
   ledger tracks dependencies manually via the orchestrator. Evaluate adopting the
   self-claiming + auto-unblock model, or mirroring file-locked claiming in the
   ledger to cut orchestrator turns on coordination.
3. **Plan-approval mode** (teammate read-only until lead approves). Maps to a
   review-before-implement gate. Evaluate as a cadence option for risky units.
4. **Subagent-definition reuse** (one definition usable as subagent or teammate).
   Align our `roles/<base>.md` format so a role doubles as a subagent definition,
   reducing duplication.
5. **Mailbox auto-delivery + idle notifications.** The bus already push-wakes via
   the Monitor tool; compare latency/ergonomics, likely skip unless clearly better.

**Do-not-regress (where we are ahead; folding in must not lose these).** Free idle
roles (Agent Teams teammates consume tokens even when idle), session resume (Agent
Teams has none for in-process teammates), multiple concurrent teams (Agent Teams:
one at a time), the readable narrative ledger/decision-log as an audit artifact,
the dedicated integrator + scope/off-limits enforcement, `api-watchdog` rate-limit
recovery.

**Constraints.** Agent Teams is still experimental (no resume, one team at a time,
task-status can lag). Not an immediate rewrite. Evaluation now, adoption gated on
Agent Teams leaving experimental. Both run on the operator's subscription, so
billing is not a deciding factor (verified, see the research doc).

**To produce.** A per-feature decision table (adopt / mirror / skip + rationale)
appended to the research doc, and a spike: gates-as-`TaskCompleted`-hook on a
throwaway Agent Teams run, to test whether the discipline layer ports cleanly.

**Depends on / strengthens.** Informs B3 (productise: a governance layer on a
first-party substrate is more shippable than a bespoke bus). Independent of B2/B4.

---

## B11 - Visual swarm dashboard (second-screen, real-time)

**What.** A read-only, canvas-style live view of the swarm to keep on a second
screen while the orchestrator runs. Nodes per live role coloured by state
(active / idle / paused / `question:` outstanding / `stalled-api` / `give-up`);
edges per recent bus message labelled with the `status:`/`done:`/`question:`/
`answer:`/`priority:` prefix and direction; a stats panel with per-role message
counts, units by status (`todo`/`in-progress`/`blocked`/`review`/`done`), a
timeline of add/retire events, and the run's cap usage. Excalidraw or a similar
canvas tool, not a TUI.

**Why.** `bin/team-status.sh` and the tmux panes are text-only and scroll past;
catching "who's stuck" or "who just sent what to whom" needs grep work. With B9
dynamic scaling making 6-12 roles realistic and B2 pushing toward unattended
runs, the operator needs an at-a-glance view that survives looking away.
"On another screen" is the point: the orchestrator pane stays where it is, the
canvas sits beside it.

**What's there to power it (lowers the cost a lot).**
- `$TEAM_DIR/active` is the roster (pid, window id, role) and is updated by
  every `add-role`/`retire-role`/`launch-team`/`stop-team` already.
- `$TEAM_DIR/state.md` carries units (with `status:` per block), the decision-log,
  and the `## roster` add/retire timeline.
- `$TEAM_DIR/health/<role>.json` already records api-watchdog state per role
  (`ok`/`stalled-api`/`give-up`) with timestamps.
- `/is` writes a `messages.log` per port that `bin/team-logs.sh` already parses
  by role; sender/recipient/prefix/time/file-pointer are all in there.
- Per-run isolation is solid (concurrency fix landed 2026-05-25), so one viewer
  per `$TEAM_DIR` is well-defined.

**Approaches to evaluate.**
1. **Static HTML + tiny JSON endpoint.** A `bin/dashboard.sh` that serves
   `127.0.0.1:<port>/state.json` from a one-shot read of `active` + `state.md` +
   `health/` + a tail of `messages.log`, plus a self-contained page that polls
   every 1-2s and lays out a force-directed graph (Cytoscape, vis.js, or
   D3-force). Most flexible, no external dependencies beyond a browser.
2. **Excalidraw-as-canvas.** Generate an Excalidraw JSON scene per refresh and
   load it via the `@excalidraw/excalidraw` library in a page. Aesthetic but
   higher cost to wire stable node identities through redraws.
3. **Mermaid live.** A page that re-renders a Mermaid `flowchart`/`sequenceDiagram`
   on each poll. Cheapest to build, less interactive (no node drag, no zoom).
4. **Adopt an existing tool.** Briefly evaluate LangGraph Studio / AutoGen Studio
   / CrewAI's UI to see whether anything maps cleanly onto our `/is` + ledger
   data without a rewrite. Likely no, but cheap to check first.

Bias toward (1) for ease and control; (2) for the look the operator asked for if
the wiring is tractable.

**Scope / considerations.**
- Read-only viewer. The orchestrator drives; the dashboard reflects. (Action
  buttons belong to B4/notify-hook, not here.)
- One viewer per `TEAM_RUN_ID`; an inbox-style picker for several concurrent runs
  (overlap with `bin/inbox.sh` — likely share that data source).
- Bind to `127.0.0.1` only. Tailnet exposure for B4 is a separate, opt-in step.
- Cadence 1-2s; the inputs are small files and a log tail.
- "Idle vs busy" for a role: derive from "no outbound message in N seconds and
  health=ok"; do not try to read tmux pane content (noisy redraws).
- Stats panel suggested fields: messages/role over the last minute and total,
  units by status, queue depth (messages with no answer:), median time to
  first answer per question:, live count vs cap.

**Depends on / strengthens.** Strengthens B2 (autonomous mode benefits most from
a glance view since the operator is not in the pane) and B9 (the larger the
team, the more value). Pairs with B4 (the dashboard URL can be tailnet-reachable
for phone use). Reuses the same data the api-watchdog and team-status already read.

---

## Prior-art findings (2026-05-24, reference for remaining items)

### Strategic headline: Anthropic is building into this space

- **Agent Teams** (local, experimental, flag `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`,
  v2.1.32+): the first-party build of this exact pattern. Persistent role sessions
  + a Mailbox (addressed messages) + a shared task list + lifecycle hooks
  (`TeammateIdle`/`TaskCreated`/`TaskCompleted`, exit 2 to block). Missing vs ours:
  enforced verify/scope gates, an integrator/merge role, a readable narrative
  ledger; also one team at a time, no session resume.
  https://code.claude.com/docs/en/agent-teams
- **Routines** (cloud, research preview, Apr 2026): single-agent scheduled
  automation (cron / one-off / HTTP / GitHub webhook), runs in Anthropic cloud.
  https://code.claude.com/docs/en/routines
- **Managed Agents multiagent** (cloud API, beta, Apr 2026): coordinator + up to
  25 delegated threads, shared container FS + vault.
  https://platform.claude.com/docs/en/managed-agents/multi-agent
- **Remote Control** (local session driven from phone/web, push, outbound-only;
  research preview Feb 2026). https://code.claude.com/docs/en/remote-control
- Closest third-party full match: **Overstory** (roles incl. a Merger, SQLite
  bus, tool-call scope guards, merge queue; small, maintenance-mode). Others do
  less (claude-squad: no coordination; Tmux-Orchestrator: send-keys, no gates) or
  sit at a different layer (claude-flow, MetaGPT, CrewAI/AutoGen/LangGraph/OpenHands).

### Our durable differentiators (not matched as a combination anywhere)

Enforced verify gate (`done` = fresh exit-0 log); git-path scope/off-limits
check; human-readable markdown ledger + decision-log (survives compaction);
dedicated integrator/merge role; clone-per-project with interactive READY-gate
steering.

### Strategic implication

The substrate (sessions / bus / tmux / scheduling / remote) is converging with
first-party primitives. Our value is the **discipline layer**: gates + ledger +
integrator + scope enforcement. Direction to track: re-target as a
governance/discipline layer on top of Agent Teams (build gates on its hooks) once
it leaves experimental, rather than maintaining the bespoke substrate. Not an
immediate rewrite: Agent Teams is experimental (no resume, one team at a time),
so the substrate still has real advantages today.

### Per-item findings

- **B2**: adopt Routines for scheduling + GitHub triggers, Managed Agents for
  cloud execution; build only the local-background + watchdog + notify glue. Keep
  human gates, made asynchronous.
- **B3 (corrected 2026-05-24)**: `/is` is the operator's OWN fork of
  github.com/yilunzhang/claude-code-inter-session (MIT). The fork
  (github.com/1-fares/claude-code-inter-session, local at
  ~/projects/claude-code-inter-session) adds 10 commits, +392/-70 over 11 files,
  including the file-pointer long-message delivery the orchestrator depends on,
  the short `/is` invocation, `/is help`, standalone auto-start handling, tests,
  and docs. Yilun's wire/server core remains; the delivery/UX/docs layer is the
  operator's. DECISION 2026-05-24: keep `/is` as a **sibling project** (a separate
  dependency the operator maintains and uses in other work), installed alongside
  the orchestrator clone, NOT bundled. Done: `/is` LICENSE carries both copyrights
  (Yilun Zhang as original author + the operator's fork line); `/is` README credits
  the upstream and drops the language cross-link; `README.zh.md` removed; the
  orchestrator README documents `/is` as a separate sibling dependency with credit.
  (Adjust the fork copyright name from "Fares" to your preferred legal name if
  needed.) One other contributor: Nicholas Moen (1 commit). Changes left
  uncommitted in both repos pending review.
  A2A/MCP are not a better foundation: the bespoke localhost websocket
  bus (riding the Monitor tool for push-wake) is correctly scoped for
  single-user/local/trusted; A2A targets cross-org/networked agents.
- **B4**: largely solved by existing tools. Best fit with no rearchitecting:
  Tailscale + mosh + `tmux attach` + an `ntfy` hook. Omnara (OSS, self-hostable)
  for a polished phone UI. First-party Remote Control steers a single session, not
  the bus/team. Security: `--dangerously-skip-permissions` + remote needs a
  sandbox (Anthropic is moving to OS-level sandboxing). The `ntfy` half is now
  in place via B8; remaining work is the SSH/mosh path and the mobile UX.

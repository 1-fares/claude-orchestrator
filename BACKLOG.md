# Backlog

Forward-looking work items, not yet scheduled. Built items live in
[STATUS.md](./STATUS.md); this file is only what is still open. Prior-art
research precedes build on all of them: adopt or integrate a mature existing
tool before reinventing.

Open: B2 (autonomous mode), B3 (portability), B4 (remote-control phone test),
B10 (fold in Agent Teams features), B12 (SDK credit pool). Built and removed
from this list: B9 (dynamic scaling), B11 (visual dashboard), and the B3
attribution/licence/CJK work; see STATUS.md.

---

## B2 - First-class autonomous mode

**What.** One command that scaffolds, launches, and runs a goal to completion
in the background, managing tmux and the bus itself and surfacing decisions
through notifications rather than a live pane.

**State.** The autonomous *cadence* already exists in `roles/orchestrator.md`
(orchestrator under `/goal` to the whole-feature acceptance), and the
prerequisites are built: per-run `TEAM_RUN_ID` isolation, recovery-aware
`bin/run.sh`, orphan-safe `bin/cleanup.sh`, the api-watchdog rate-limit
recovery, and the `ntfy` push channel. Not built: the packaged single command
and the notify-and-resolve loop around it.

**To build.**
- `bin/run.sh --auto "<goal>" [--accept "<exit-0 cmd>"] [--max-rounds N] [--notify <ntfy-url>]`:
  launch detached, return the run-id, print `TEAM_RUN_ID=<id> bin/attach.sh` for
  later. Reuses today's per-run isolation so several auto runs coexist.
- Notify-and-resolve: on a blocker, write `$TEAM_DIR/PENDING.md` (question +
  suggested answers + resolution command) and push an ntfy body that is enough
  by itself (run-id, target, question, attach command). `bin/inbox.sh` already
  lists every run awaiting input.

**Hard rule.** Autonomous does not mean silent. The human gate is asynchronous,
not removed: notify and wait, do not silently decide.

**Safety.** Autonomous + `--dangerously-skip-permissions` is unattended code
execution; safety rests on the existing gates (verify, per-unit scope baseline,
branch isolation, integrator merge on `orch/...`), off-limits paths in the
brief, and `bin/panic.sh` as the kill switch. `bin/cleanup.sh` never auto-kills.

**Depends on.** Shares most of its surface with B4 (notification + reply
channels); best designed together.

---

## B3 - Portability for other environments

**State.** The public-release blockers are cleared: LICENSE (MIT), `/is`
attribution to the upstream author in the README, and no bundled CJK text (the
`/is` fork carries both copyright lines; see the prior-art note below). What
remains is portability.

**To do.**
- Run beyond WSL/Linux: macOS, other shells, paths with spaces.
- A dependency preflight with clear errors for a missing `tmux`, `claude`, `uv`,
  `python3`. None exists today.
- Confirm the clone-per-project model and concurrent-team behaviour on a fresh
  machine.

---

## B4 - Remote / mobile control

**State.** Primary path is first-party `/remote-control` (outbound-only, mobile
app, push on input-needed). Escape-hatch helpers are built and locally verified:
`bin/team-status.sh --mobile`, `bin/inbox.sh`, `bin/approve.sh`, and the
off-by-default action-button hook (`bin/notify-hook.py` + `bin/sign-action-url.sh`
+ `bin/notify-via-ntfy.sh`, HMAC-signed URLs with a 30-min TTL).

**Open.** The end-to-end `/remote-control` phone walkthrough (README "Remote
control from a phone", Steps 1-8) has not been run. Reaching the host for the
escape hatch (Tailscale, Cloudflare Tunnel) is a separate opt-in step; if set
up, point `NOTIFY_HOOK_BASE` at the reachable IP.

**Gap `/remote-control` does not cover.** The api-watchdog's stall / recovery /
give-up signals do not flow through it; they only fire when Claude itself needs
input. Keep both apps on the phone: the Claude app for `/remote-control`, the
ntfy app for watchdog pushes.

---

## B10 - Fold Agent Teams features into the orchestrator

**What.** Assess each first-party Agent Teams capability and decide per feature
whether to adopt, mirror, or skip it. Full comparison and evidence in
[docs/native-agents-comparison.md](docs/native-agents-comparison.md).

**Why.** Agent Teams (local, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`,
v2.1.32+) is the first-party build of this pattern. The substrate is converging;
the durable value here is the discipline layer (gates + ledger + integrator +
scope). The strategic question is whether to keep the bespoke `/is` substrate or
re-target the discipline layer onto Agent Teams once it leaves experimental.

**Candidates (adopt / mirror / skip).**
1. **Quality-gate hooks** (`TaskCompleted` / `TaskCreated` / `TeammateIdle`,
   exit 2 to block). Highest leverage: prototype `verify-unit.sh` +
   `check-scope.sh` as a `TaskCompleted` hook; if it works, the discipline layer
   becomes portable and `/is` can eventually retire.
2. **Shared task list** (auto dependency unblock + file-locked claiming). Evaluate
   adopting the self-claiming model, or mirroring file-locked claiming in the
   ledger to cut orchestrator coordination turns.
3. **Plan-approval mode** (teammate read-only until lead approves). A cadence
   option for risky units.
4. **Subagent-definition reuse.** Align `roles/<base>.md` so a role doubles as a
   subagent definition.
5. **Mailbox auto-delivery + idle notifications.** The bus already push-wakes via
   the Monitor tool; compare, likely skip unless clearly better.

**Do-not-regress (advantages folding-in must keep).** Free idle roles, session
resume, multiple concurrent teams, the readable narrative ledger, the dedicated
integrator + scope enforcement, api-watchdog recovery. Agent Teams lacks all of
these today (experimental: no resume, one team at a time).

**To produce.** A per-feature decision table appended to the research doc, and a
spike of gates-as-`TaskCompleted`-hook on a throwaway Agent Teams run.

---

## B12 - Route eligible work onto the Agent SDK credit pool

**State: research done, not implemented. Its 2026-06-15 start date has passed;
the pool now exists but no orchestrator call site targets it.**

**The finding.** Since 2026-06-15, Claude Agent SDK and `claude -p` usage no
longer counts toward the interactive subscription limits; it draws from a
separate per-tier monthly pool (Max 20x: $200/month at API rates, per user, no
rollover). Interactive Claude Code sessions, Claude.ai, and Cowork are
unaffected. Overage falls through to usage credits (prepaid, billable at API
rates) or fails if usage credits are not enabled.

**Why it matters.** Role sessions launch as ordinary subscription-authenticated
`claude` processes drawing from the interactive pool. Eligible work re-routed
onto the SDK pool is free headroom: roughly $200/month of API-priced inference
per user that otherwise eats the interactive quota or goes unspent.

**To evaluate, in order of bluntness.**
1. Identify pool-eligible call sites: only Agent SDK and `claude -p`
   (non-interactive) qualify. Candidates: deterministic batch jobs the
   orchestrator shells out for (verifier summarisation, bus-message triage,
   scope-check explanations), and the gate helpers already one-shot LLM calls
   (`bin/gates/llm-judge`, `rubric-judge`, `cite-support`).
2. Route those via subscription-authenticated SDK / `claude -p` so they draw
   from the pool rather than a Console API key.
3. Cap detection and fallback: fail fast (cost-safe, may stall a run) or fall
   through to usage credits with a hard monthly ceiling. Document the choice.

**Not eligible / out of scope.** Interactive role sessions (keep drawing the
interactive pool), background sessions (`claude --bg`, `claude agents`, billed as
interactive), and Claude Managed Agents (Console-key billed, unaffected by the
change).

**Sources (verified 2026-05-27).**
- [Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Manage usage credits for paid Claude plans](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans)
- [Claude API pricing (Managed Agents section)](https://platform.claude.com/docs/en/about-claude/pricing)

---

## Prior-art findings (reference)

**Anthropic is building into this space.** The substrate (sessions / bus / tmux /
scheduling / remote) is converging with first-party primitives:

- **Agent Teams** (local, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`,
  v2.1.32+): persistent role sessions + Mailbox + shared task list + lifecycle
  hooks. Missing vs here: enforced verify/scope gates, an integrator role, a
  readable ledger; also one team at a time, no session resume.
  <https://code.claude.com/docs/en/agent-teams>
- **Routines** (cloud, single-agent scheduled automation: cron / one-off / HTTP /
  GitHub webhook). <https://code.claude.com/docs/en/routines>
- **Managed Agents multi-agent** (cloud API: coordinator + up to 25 delegated
  threads, shared container FS + vault).
  <https://platform.claude.com/docs/en/managed-agents/multi-agent>
- **Remote Control** (local session driven from phone/web, push, outbound-only).
  <https://code.claude.com/docs/en/remote-control>
- Closest third-party match: **Overstory** (roles incl. a Merger, SQLite bus,
  tool-call scope guards, merge queue; small, maintenance-mode). Others do less
  or sit at a different layer (claude-flow, MetaGPT, CrewAI/AutoGen/LangGraph).

**Durable differentiators (not matched as a combination anywhere).** Enforced
verify gate (`done` = fresh exit-0 log); git-path scope/off-limits check;
human-readable markdown ledger + decision-log (survives compaction); dedicated
integrator/merge role; clone-per-project with an interactive READY gate.

**Strategic direction.** Track re-targeting the discipline layer (gates + ledger
+ integrator + scope) onto Agent Teams once it leaves experimental, rather than
maintaining the bespoke substrate indefinitely. Not an immediate rewrite: Agent
Teams' experimental limits (no resume, one team at a time) still leave real
advantages here today. Both run on the operator's subscription, so billing is not
a deciding factor.

**On the `/is` bus (B3 decision).** `/is` is the operator's fork of
[yilunzhang/claude-code-inter-session](https://github.com/yilunzhang/claude-code-inter-session)
(MIT). It ships as a **sibling project**, a separate dependency installed
alongside the orchestrator clone, not bundled. The fork adds the file-pointer
long-message delivery the orchestrator depends on, the short `/is` invocation,
auto-start handling, tests, and docs. A2A/MCP are not a better foundation: the
localhost websocket bus (riding the Monitor tool for push-wake) is correctly
scoped for single-user/local/trusted use; A2A targets cross-org networked agents.

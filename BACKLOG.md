# Backlog

Forward-looking work items, last updated 2026-05-25. Not yet scheduled. B3 is
discussion-only for now (no changes until agreed). Prior-art research precedes
build on all of them: adopt or integrate mature existing tools rather than
reinvent.

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

## B4 - Remote / mobile control

**What.** Drive the system from a phone: one session running on the machine,
connect remotely, kick off and monitor builds and debugging, large and small.

**Why.** The tmux substrate already makes this largely an SSH-plus-attach
problem; high convenience for low mechanism.

**Scope / considerations.**
- SSH or mosh plus tmux attach from a mobile terminal; `team-status.sh` as a
  compact mobile dashboard.
- Push notifications when input is needed or a run finishes.
- Security: exposing SSH; running unattended `--dangerously-skip-permissions`
  triggered remotely; answering the READY gate and menus on a small screen.
- Evaluate Claude Code's own remote/web/cloud surfaces vs a plain SSH+tmux path.

**Depends on.** B2 (background + notify).

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

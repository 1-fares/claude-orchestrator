# Backlog

Forward-looking work items, captured 2026-05-24. Not yet scheduled. B3 is
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
- Notification on done / blocked / needs-input (ties to B4 push).
- A watchdog for orphans; never leak tmux servers, bus servers, or pids across
  many runs. (Teardown was reliable in testing: every `reset.sh` killed the
  session, reaped the tree, and stopped the bus on its port.)
- Keep human gates as asynchronous (notify and wait), do not remove them: the
  orchestrator's clarifying questions were valuable in testing.

**What's already in place that lowers the cost.** Per-run `TEAM_RUN_ID` isolation
(parallel teams trivially), recovery-aware `bin/run.sh`, orphan-safe
`bin/cleanup.sh`, the `interactive | autonomous` mode is already a concept in
`roles/orchestrator.md`, and the orchestrator can be driven programmatically
(proven during testing).

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

## B5 - Non-code domains (multi-role for research, writing, slides, legal)

**What.** Apply the goal / ledger / role / gate paradigm to non-code work:
research reports, papers, PowerPoint, legal analysis, with roles such as
researcher, writer, editor, fact-checker, reviewer.

**Why.** The orchestration core is domain-neutral; only the gates and some
conventions assume code.

**Scope / considerations.**
- Domain role libraries (`roles/*.md`).
- Pluggable per-unit gates: `verify` becomes a rubric, fact-check, citation, or
  format check rather than an exit-0 command (gate-waiving already exists and was
  used for the design-doc unit in testing).
- Outputs via the office/docx skills already available.
- Legal carries real accuracy and liability risk: mandatory citation and
  fact-check gates, explicit disclaimers, treat as research-assist not advice.
- Start with one pilot domain (research or writing) before generalising.

**Depends on.** Pressures the core to decouple from code assumptions, which also
helps B3.

---

### Detailed plan (2026-05-24): pilot = Swiss legal case-prep (research-assist)

**Headline.** Pilot is Swiss legal case preparation. Generic public-domain
example: review of a sample employment contract under Swiss CO Art. 319+.
Multilingual sources (DE/FR/IT), English memo. Citation verification is
deterministic via fedlex.admin.ch and entscheidsuche.ch. Research corpus is web
only (GPT Researcher via `gptr-mcp` + WebFetch); no local PDF curation.
Pragmatic tool depth: pandoc + GPT Researcher + a ~50 LOC Swiss-law-search
helper. Legal is treated as a worked example of the generic non-code capability,
not as a structurally fortified special case.

**Honest tension to note.** Prior-art research (and Agent 1 here) ranked legal
*last* among candidate pilots: Stanford 2025 found even purpose-built legal RAG
fabricates ~1 in 6; lawyers have been sanctioned for AI fake-citations. The
operator chose legal anyway; the design below compensates with sharper safety
(deterministic cite-verification, forbidden-phrase scan, mandatory disclaimers,
human-review-required framing).

**Pipeline (roles).**
`case-analyst → legal-researcher → drafter → citation-verifier → editor →
peer-counsel-reviewer → disclaimer-officer → doc-integrator`. Each role gets
exactly one kind of mistake to catch (per Agent 3's "single load-bearing job"
principle).

**Tier-1 gate library** (`bin/gates/`, each well under 100 LOC):
- `structure.sh` — required sections + word/section counts.
- `link-live.sh` — `lychee` over cited URLs.
- `cite-resolve.sh` — every cite has a bibliography entry, every entry is cited.
- `md-lint.sh` + `office-wellformed.sh` — markdown clean; docx/pptx parses.
- `llm-judge.sh` — generic LLM-judge helper (rubric.md + artifact → JSON score,
  K=3 self-consistency for high-stakes gates, audit log under
  `$TEAM_DIR/audit/<unit>/`, evidence-anchored scoring per RULERS, explicit
  "insufficient_evidence" option per PaperQA2).
- `rubric-judge.sh` — thin wrapper on `llm-judge.sh` for per-unit rubric scoring.
- `cite-support.sh` — LLM-judge that the cited passage actually supports the
  claim (cornerstone for legal).
- **`swiss-cite-exists.sh`** (legal-specific) — parse BGE / ATF / Art./Abs./Bst.
  patterns; verify against fedlex + entscheidsuche.
- **`no-advice.sh`** (legal-specific) — forbidden-phrase scan (no "you should",
  no "we conclude", no "the court will rule") + mandatory disclaimer presence.

**Tool stack.**
- **Pandoc + CSL/BibTeX** — markdown → DOCX/PDF with a Swiss-legal reference
  template.
- **GPT Researcher (`gptr-mcp`)** — wired as the legal-researcher's MCP tool; web
  research over public Swiss sources (fedlex, bger.ch, entscheidsuche.ch).
- **`bin/tools/swiss-law-lookup.sh`** — tiny wrapper (~50 LOC) over the free
  entscheidsuche.ch + fedlex.admin.ch search/URL conventions; used by both the
  researcher and the `swiss-cite-exists` gate.
- Tier 2 / skip: PaperQA2 (no local PDFs by user choice; revisit if they
  appear), STORM, Marp/python-pptx (not slides), Elicit/Consensus (paywall).

**Safety / defaults** (refined with operator 2026-05-24; per-goal tunable):
1. **Disclaimer**: default-on ("DRAFT FOR ATTORNEY REVIEW — NOT LEGAL ADVICE",
   jurisdiction, date). The goal brief may opt out per memo.
2. **No conclusions/advice/predictions** is NOT structurally enforced. Drafts
   may make conclusions, predictions, even advice. The `no-advice.sh` gate
   exists and any goal can opt into it via its `verify:` line; default is off.
3. **Cite verification** mandatory at the INTEGRATION step only (not per
   per-section draft): the integrator runs `swiss-cite-exists` + `cite-support`
   and rejects the artifact on any unverified cite.
4. **Peer-counsel-reviewer** optional; the orchestrator chooses per goal.
5. **Data scope**: no restriction. Goals can take any input the operator
   chooses (public domain, fictional, confidential). Operator manages
   confidentiality.
6. **Off-limits**: same as any goal; no legal-specific operational restrictions.
   The goal brief sets its own off-limits and scope per the existing
   `check-scope.sh` mechanism.

The user explicitly traded a structurally-fortified legal mode for a generic
non-code capability with legal as one worked example. Cite-verification at
integration + default disclaimer remain the structural safety; the rest moves to
operator judgement per goal.

**Files to ship in the MVP** (no core changes):
- `roles/`: `case-analyst.md`, `legal-researcher.md`, `drafter.md`,
  `citation-verifier.md`, `peer-counsel-reviewer.md`, `disclaimer-officer.md`,
  `doc-integrator.md` (in existing role-file shape).
- `bin/gates/`: the 9 gate scripts above.
- `bin/tools/swiss-law-lookup.sh`.
- `templates/`: `legal-rubric.md`, `legal-memo-template.md`,
  `reference-legal.docx` (pandoc reference doc with cover-page disclaimer),
  `bibliography.csl` (Swiss legal style).
- `goals/_example-legal-case-prep.md`: the sample pilot goal (sample employment
  contract under CO 319+).
- Light additions to `roles/_TEMPLATE.md` (lane-discipline paragraph + non-code
  gate hint per Agent 3) and a paragraph each in `CLAUDE.md` / `QUICKSTART.md`.

**Expected pilot output.** A ~10-15 page memorandum (DOCX + PDF) on a sample
Swiss employment-contract review question, multilingual sources cited in English
prose with original-language quotes for key terms, all gates green, cover-page
disclaimer, handed to a qualified human lawyer for final review.

**Status.** Plan finalized 2026-05-24 from 4 parallel research agents +
operator clarifications. Not built yet.

---

## Prior-art findings (2026-05-24, reference for B2-B5)

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
  sandbox (Anthropic is moving to OS-level sandboxing).
- **B5**: integrate, do not rebuild, for research (GPT Researcher, PaperQA2,
  STORM) and legal (Harvey/CoCounsel; autonomous legal output is a no-go, ~1 in 6
  fabrication even in purpose-built tools). Genuine gaps: writing/editing
  pipelines and content-correct slides. Required core change: **pluggable
  non-exit-0 gates** (citation / fact-check / rubric-judge), which is also our
  cross-domain differentiator.

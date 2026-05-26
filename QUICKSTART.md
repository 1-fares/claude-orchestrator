# QUICKSTART

Operator's guide for driving the orchestrator end to end. One screen.

## Prereqs

- `tmux` (any modern version), `claude` (Claude Code CLI), `uv`, `python3`.
- The `/is` (inter-session) sibling project installed as a Claude Code skill, see
  `../claude-code-inter-session/` and its README. The orchestrator depends on it.
- A clone of this repo (this is a template; one clone per project is the norm).

## Start a run

```
cd ~/projects/claude-orchestrator
bin/run.sh
```

`run.sh` allocates a fresh `TEAM_RUN_ID`, spawns the orchestrator into a tmux
session, and attaches you. You land in the **orchestrator** (window 0).

The orchestrator now asks you, **in the session**, for:

1. **Working tree** (new path / existing repo / this clone).
2. **What to build or change** (free text).
3. Optional constraints, mode (interactive / autonomous), and any team hints.

It echoes your brief back, writes the goal file, builds its `.team-<run-id>/`
ledger, breaks the work into units, and presents a **READY** summary.

You type `go` to start, or any adjustment (different acceptance, different team)
and `go`. Specify roles by name; arbitrary roles (e.g. `ux-designer1`, `android1`,
`graphic-designer1`) are auto-supported, the orchestrator authors role files for
ones it does not have.

## Drive the team

- **Switch windows**: tmux prefix (`Ctrl-b` by default; this clone imports your
  `~/.tmux.conf` prefix) then the window number. `prefix w` lists windows;
  `prefix n` / `prefix p` cycle.
- **Watch the substance**: the tester and reviewer windows usually surface the
  real findings.
- **Answer the orchestrator** in window 0: free text, or for menus use `↑/↓` then
  `Enter` (verify the highlighted row).
- **Detach safely**: `prefix d`. Reattach with `bin/attach.sh`.
- **Monitor without attaching** (any terminal): `bin/team-status.sh` (snapshot) or
  `bin/team-watch.sh` (live). Per-role history: `bin/team-logs.sh <role>`.
- **Inject from outside**: `bin/team-broadcast.sh "<message>"` (honors
  `pause:` / `resume:` / `priority:` conventions).

### Do **not** end the orchestrator with `Ctrl-d`

`Ctrl-d` exits the orchestrator process but leaves role sessions running as
orphans (claude survives signals). Use `prefix d` to detach, or `bin/stop-team.sh`
/ `bin/reset.sh` to end the run cleanly.

## End or restart

| You want to                                  | Do this                            |
| :------------------------------------------- | :--------------------------------- |
| End the roles, keep the orchestrator         | `bin/stop-team.sh`                 |
| End everything, clear this run's state       | `bin/reset.sh`                     |
| Emergency stop (everything, no save)         | `bin/panic.sh`                     |
| Recover from a misfire / orphans / no state  | `bin/cleanup.sh` (dry-run first)   |

`run.sh` is itself recovery-aware: on start it detects any live run on the team
socket and offers to attach or start a new parallel run.

## Non-code work (any topic)

The system is domain-neutral. Beyond coding, the team can do research, writing,
slide content, legal analysis, anything the operator briefs.

- **Reference role library** at `roles/`. The curated set codifies the
  structural pipeline (`researcher`, `writer`, `editor`, `fact-checker`,
  `copy-editor`, `peer-reviewer`, `doc-integrator`) and three cross-cutting
  legal references (`paralegal`, `lawyer`, `swiss-law-specialist`). Anything
  more specific you can name on the fly: `employment-lawyer1`, `tenancy-lawyer1`,
  `market-analyst1`, `book-editor1`, `course-designer1`, whatever fits the goal.
  Any role name with no file gets auto-authored by the orchestrator from
  `roles/_TEMPLATE.md` with a prompt tailored to that role and your goal.
- **Gate library** at `bin/gates/`: wrap non-binary checks as the unit's
  `verify:` line.

  | Gate | What it checks |
  |---|---|
  | `structure.sh <art> <rules.yml>` | Required headings + word/section counts |
  | `link-live.sh <path>` | Every URL in the artifact returns 2xx |
  | `cite-resolve.sh <art> <bib>` | Every cite has a bibliography entry and vice versa |
  | `md-lint.sh <path>` | Markdown well-formed (`markdownlint-cli2`) |
  | `office-wellformed.sh <file>` | `.docx`/`.pptx` opens cleanly and has content |
  | `llm-judge.sh <art> <rubric.md>` | LLM-judge against a rubric; K-vote, audit log |
  | `rubric-judge.sh <art> <rubric.md>` | Thin wrapper on `llm-judge` for per-unit rubrics |
  | `cite-support.sh <art>` | LLM-judge that cited sources support the claims |

  Example `tasks/<unit>.md` `verify:` line:
  `bash $ORCH_HOME/bin/gates/structure.sh draft.md rules.yml && bash $ORCH_HOME/bin/gates/cite-resolve.sh draft.md refs.md`
- **Tools.** Pandoc (`pandoc --citeproc --bibliography=refs.bib --csl=style.csl
  in.md -o out.docx`) for Markdown ↔ DOCX/PDF. GPT Researcher via the
  `gptr-mcp` MCP server can be wired into a researcher role for web research.
- **Domain overlays** (Swiss legal cite-verifier, RFP compliance matrix, etc.)
  are added on demand; not in the substrate.

## Visual dashboard (second screen)

`bin/launch-team.sh` auto-starts `bin/dashboard.sh`, a read-only HTTP viewer
designed to sit on a second screen during a run. It serves a force-directed
graph of live roles plus a stats panel from data files under `$TEAM_DIR`
(roster, ledger, watchdog health, bus log). The launcher prints the URL on
start, e.g. `dashboard started (pid …) — open http://127.0.0.1:<port>/`.
The same URL is also written to `$TEAM_DIR/dashboard.url`.

It is loopback-only (127.0.0.1), pure read-only (no buttons), and cleaned up
by `stop-team.sh`, `panic.sh`, `reset.sh`, and `cleanup.sh`.

Run it standalone (no live team needed; degrades gracefully):

```
bin/dashboard.sh                       # auto-pick free port; $TEAM_DIR or newest .team-*
bin/dashboard.sh --port 8765           # fixed port
bin/dashboard.sh --team-dir .team-r123 # point at a specific run
bin/dashboard.sh --help                # all options
```

Disable auto-start: `DASHBOARD_DISABLED=1 bin/run.sh ...`.
Fixed port at launch: `DASHBOARD_PORT=8765 bin/run.sh ...`.

## API rate-limit resilience

Transient Anthropic API rate-limit / network errors stall a role's pane with a
`try again` prompt; in a multi-role run, an unwatched stall halts the team
silently. `bin/launch-team.sh` auto-starts `bin/api-watchdog.sh`, a pure-shell
daemon that scans every team window, detects the stall, and sends `try again`
with exponential backoff (30s → 60s → 120s → 300s → 600s, max 5 retries). It
records per-role state in `$TEAM_DIR/health/<role>.json` (visible in the
`HEALTH` column of `bin/team-status.sh`) and pushes `ntfy` on state changes
(first stall, recovery, give-up) when `NTFY_URL` is set.

```
# Pick any ntfy topic (account-free; just open it in the ntfy phone app):
export NTFY_URL=https://ntfy.sh/orch-<your-handle>-<random>
bin/run.sh ...
```

The watchdog makes no Claude API call, so it cannot itself be rate-limited.
Patterns it looks for live in `bin/api-watchdog.patterns` (edit freely).
Disable with `API_WATCHDOG_DISABLED=1`.

## Remote control from a phone

Two paths, used together:

### Primary: Claude Code Remote Control (`/remote-control`)

First-party, outbound-only, polished mobile app. The right default for driving
the orchestrator from the phone. Setup is trivial:

```bash
# Inside the orchestrator pane (or any claude session you want to reach):
/remote-control            # or short alias: /rc
```

A QR code appears; scan it with the Claude mobile app (iOS or Android, same
claude.ai account). The conversation now syncs to the phone. Push notifications
fire when Claude needs input (enable in `/config` -> "Push when Claude decides",
requires Claude Code v2.1.110+).

What it covers: the 95% case of typing replies at READY gates, answering
clarifying questions, reading orchestrator output. No host-side network setup.
No SSH, no Tailscale, no port forward.

What it does NOT cover: the role-window scrollback (tester/reviewer; their
substance lives in separate tmux windows that `/remote-control` does not expose),
arbitrary shell commands on the host, custom action buttons tied to the
watchdog's stall signals, and run-lifecycle commands (start / tear-down / switch
between parallel runs). Reach for the escape hatch when you need any of those.

Note: `/remote-control` is tied to the lifetime of the host's `claude` process.
If the terminal closes, the session ends. The tmux substrate survives that;
`/remote-control` does not.

### Watchdog notification channel: ntfy (B8)

The api-watchdog's stall / recovery / give-up signals do NOT flow through
`/remote-control`. They live on the ntfy topic configured in `NTFY_URL` and
arrive on the ntfy mobile app. Keep both apps on the phone.

### Escape hatch: shell-from-phone helpers (optional)

These exist for when `/remote-control` is not enough -- you actually need to run
`bin/inbox.sh`, `bin/cleanup.sh`, or read a role window's scrollback in tmux.
They work from any SSH session on the host (laptop, secondary terminal, or a
phone SSH client over a tunnel you have set up):

- `bin/team-status.sh --mobile` -- ~40-column compact dashboard
- `bin/inbox.sh` -- every parallel run on this clone with run-id, age, last
  orchestrator message, attach + approve commands
- `bin/approve.sh [<text>]` -- send `<text>` (default: `go`) to a specific
  run's orchestrator pane (`TEAM_RUN_ID=<id> bin/approve.sh`)

A signed-action-URL HTTP hook is also in the tree (`bin/notify-hook.py` +
`bin/sign-action-url.sh` + `bin/notify-via-ntfy.sh`) for the case where you
want tap-to-approve / tap-to-pause action buttons embedded in ntfy pushes.
The hook makes no Claude API call. URLs carry HMAC(METHOD\nPATH\nEXP) with
a 30-minute default TTL. It is OFF by default; start it manually
(`bin/notify-hook.py --bind <reachable-ip> --port 8421`) if you decide you want
it. A first-party `/remote-control` push usually beats it; the hook is here for
when a button is genuinely more convenient than opening the mobile app.

Reaching the host from the phone is a separate problem (Tailscale, Cloudflare
Tunnel, or anything else you prefer); not documented here because it is not
needed for the primary path. If you set one up, point `NOTIFY_HOOK_BASE` at the
reachable IP and the URL signer will use it automatically.

## Parallel runs (same clone)

Every `bin/run.sh` invocation gets its own `TEAM_RUN_ID`, so its own bus port,
tmux session, and state dir (`.team-<run-id>/`), no name collisions across
teams. To address a specific run: `TEAM_RUN_ID=<id> bin/attach.sh` (or any other
script). `bin/attach.sh <session-name>` picks among parallel sessions
(`tmux -L orchestrator ls` lists them).

## Cheat-sheet

```
START / ATTACH
  bin/run.sh                       start (or attach existing); asks goal in-session
  bin/attach.sh                    attach this run's session
  bin/attach.sh <session>          attach a specific parallel run

INSIDE TMUX
  prefix <N>     switch to window N        prefix w     window list
  prefix n / p   next / prev window        prefix d     detach (SAFE; do NOT Ctrl-d)

MONITOR (from any terminal)
  bin/team-status.sh               one-glance dashboard
  bin/team-watch.sh                live dashboard
  bin/team-logs.sh [<role>]        per-role message history (durable)

CONTROL
  bin/team-broadcast.sh "<msg>"    inject to every role
  bin/stop-team.sh                 end roles, keep orchestrator
  bin/reset.sh                     end everything + clear this run's state
  bin/cleanup.sh                   dry-run detect orphans/misfires
  bin/cleanup.sh --force --purge   apply (only this clone's team; safe)
  bin/panic.sh                     emergency stop (last resort)

PARALLEL
  TEAM_RUN_ID=<id> bin/run.sh ...  pre-set the run id (else auto-allocated)
  TEAM_RUN_ID=<id> bin/attach.sh   attach a specific run
```

## When something looks wrong

- `bin/team-status.sh` to see role liveness + last message.
- A role window stuck? Switch in (`prefix <N>`) and read its scrollback
  (`prefix [`, then `PgUp`; `q` to exit scroll mode).
- The orchestrator asking a confusing question? Reply with `question: ...` to
  push back, or use the READY override and `go`.
- Lost the terminal but the team's still running? Closing a terminal **detaches**;
  `bin/attach.sh` brings you back.

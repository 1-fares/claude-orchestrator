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

## Remote control from a phone (Tailscale + SSH + ntfy)

The substrate is already there: tmux sessions survive disconnects, `bin/attach.sh`
re-enters a specific run, ntfy delivers stall / question / done pushes (B8). What
this section adds is a path from the phone to those primitives.

### One-time setup

**1. Tailscale on the WSL2 host.** Tailscale is the network layer; it gives the
WSL2 host a stable `100.x.y.z` IP reachable from any device on your tailnet,
without router config and without exposing anything publicly.

```bash
# Inside WSL2 (Ubuntu)
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled        # needs WSL2 systemd; modern WSL2 has it
sudo tailscale up                             # opens an auth URL; sign in once
tailscale ip -4                               # note this address; the phone will use it
```

If `systemctl` reports `System has not been booted with systemd`, enable it in
`/etc/wsl.conf` (`[boot]\nsystemd=true`), `wsl --shutdown` on the Windows side,
relaunch, then retry. (Required once per WSL distro.)

**2. Tailscale Android app.** Install from Play Store, sign in with the same
account. The phone now sees the WSL2 host's `100.x.y.z`.

**3. SSHd in WSL2.** WSL2 ships `openssh-server` but does not auto-start it:

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

Generate an SSH keypair on the phone (ConnectBot: menu → Manage Pubkeys → Generate),
copy the public key, paste it into `~/.ssh/authorized_keys` on the WSL2 host.

**4. ConnectBot connection.** Add a host: `user@100.x.y.z`, select the pubkey,
connect. You should land in a shell.

Optional but recommended: in ConnectBot's host settings, map **Volume Down** to
`Ctrl` (Settings → Other → Camera/Volume Up/Down behaviour). Tmux prefix
(`Ctrl-a` / `Ctrl-b`) becomes Volume-Down + a/b. Much faster than the on-screen
modifier.

### Day-to-day flow

```
phone wakes:    ntfy push: 🟠 [orchestrator/wd-abc-123] role 'tester2' stalled
phone taps:     opens ConnectBot → SSH session → bin/inbox.sh
                                  (shows every run awaiting input)
phone types:    TEAM_RUN_ID=wd-abc-123 bin/attach.sh   (lands in the right session)
                ... read the question, type the answer, prefix-d to detach
                ... session keeps running on the WSL2 host
```

If you want roaming-stable sessions (WiFi → cellular without losing the attach),
install **Termux** from F-Droid (free; the Play Store version is unmaintained),
`pkg install mosh openssh`, and use `mosh user@100.x.y.z -- tmux -L orchestrator
attach -t <session>`. ConnectBot is SSH-only and drops on network hand-off.

### Compact mobile commands

These exist for the small-screen case:

- `bin/team-status.sh --mobile` -- ~40-column dashboard, fits portrait phone
- `bin/inbox.sh` -- every parallel run currently awaiting input, across all run-ids
- `bin/approve.sh <run-id> [<text>]` -- send `<text>` (default: `go`) to that run's orchestrator

### Action-button push notifications (Tier 2)

Tap **approve / pause / stop** on the phone's ntfy notification, no terminal
needed. Implemented end to end:

- `bin/notify-hook.py` -- a single-file Python daemon (uv-run, stdlib only) that
  listens for HMAC-signed action URLs and dispatches via `bin/approve.sh` or
  `bin/team-broadcast.sh`. The hook makes no Claude API call and holds no per-team
  state of its own.
- `bin/sign-action-url.sh` -- generates the signed URLs; used by the orchestrator
  and watchdog when emitting `Actions:`-tagged ntfy pushes.
- `bin/notify-via-ntfy.sh` -- one-line helper to send an ntfy push with one or
  more `--action approve|pause|resume|stop|priority` buttons that call the hook.

**Set it up once.** First run of `notify-hook.py` writes a random 32-byte HMAC
secret to `~/.claude/notify-hook.secret` (0600). Keep that file private; with it,
URLs are forgeable.

```bash
# Bind to the tailnet IP so the phone can reach it; localhost-only by default.
nohup bin/notify-hook.py --bind "$(tailscale ip -4)" --port 8421 \
  > ~/.claude/notify-hook.log 2>&1 &
echo $! > ~/.claude/notify-hook.pid

# Tell the helpers where the hook lives (add to ~/.bashrc to persist):
export NOTIFY_HOOK_BASE=http://$(tailscale ip -4):8421
```

**Try one push with buttons:**

```bash
TEAM_RUN_ID=<run-id-you-want-to-target> \
  bin/notify-via-ntfy.sh --title READY --body "ready to start?" \
  --action approve --action pause
```

Phone receives a push with two buttons; a tap fires an HMAC-signed HTTP GET that
the hook validates and dispatches. URLs have a 30-minute TTL by default
(`--ttl` on `sign-action-url.sh`).

**Safety properties.** Every URL carries an HMAC of `METHOD\nPATH\nEXP`; tampering
or replay after expiry returns 403. The hook never touches a session it cannot
positively dispatch to; it logs every accept and reject to `$NOTIFY_HOOK_LOG`
(append-only). Lost the secret? Rotate it: stop the hook, `rm ~/.claude/notify-hook.secret`,
restart. Existing URLs become invalid; re-send any outstanding pushes.

### Threat model

- Tailscale is private (your tailnet only); WSL2 sshd is not exposed publicly.
- SSH key on the phone is guarded by the phone's biometric / PIN at unlock.
- ntfy.sh topic is public: anyone who knows `myteam-orchestrator` can read
  your pushes. Operational content only; rotate to a long-random topic if you
  add anything sensitive. Self-host ntfy on the same WSL2 host (Tailscale-only)
  if you want fully-private pushes.

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

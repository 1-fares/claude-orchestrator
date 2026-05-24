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

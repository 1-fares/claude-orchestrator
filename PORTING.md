# Porting claude-orchestrator to GitHub Copilot CLI

> **Branch**: `copilot-port`  
> **Status**: scaffold in progress — stubs ready, implementation pending  
> **All port files live under `copilot/`** — existing Claude Code files are untouched.

---

## 1. What this system does

`claude-orchestrator` is a multi-agent team coordination system. One **orchestrator**
session owns a goal, maintains a ledger (`state.md`), and assigns units of work to
specialized **role** sessions. Roles communicate over a real-time P2P message bus
(`/is`), report progress with structured prefixes, and a `done:` claim requires
passing two gate scripts before it's accepted.

The system is composed of two projects:

| Project | Role |
|---|---|
| `claude-code-inter-session` | WebSocket message bus + `/is` Claude Code skill |
| `claude-orchestrator` | Orchestrator pattern, roles, shell scripts, gates |

---

## 2. Dependency map: what depends on Claude Code vs. what is generic

### 2a. Generic (no changes needed)

| Component | Why it's portable |
|---|---|
| `roles/*.md` | Plain Markdown; Copilot reads `CLAUDE.md` natively |
| `CLAUDE.md` | Copilot reads it natively (also `AGENTS.md`, `.github/copilot-instructions.md`) |
| `goals/*.md`, `tasks/*.md` | File-based — no tool dependency |
| `templates/state.md` | File-based ledger |
| `bin/verify-unit.sh`, `bin/check-scope.sh`, `bin/unit-start.sh` | Pure shell |
| `bin/team-broadcast.sh`, `bin/approve.sh` | tmux send-keys — model-agnostic |
| `bin/worktree.sh`, `bin/reset.sh`, `bin/roster.sh` | Pure shell / git |
| `bin/team-env.sh` | Pure shell env derivation |
| `bin/preflight-deploy.sh` | Pure shell |
| `bin/notify-via-ntfy.sh`, `bin/notify-hook.py`, `bin/sign-action-url.sh` | Pure shell/Python |

### 2b. Needs adaptation (Claude Code CLI flags → Copilot CLI flags)

| Component | Change |
|---|---|
| `bin/run.sh` | `claude` → `copilot`; flags: `--dangerously-skip-permissions` → `--allow-all` |
| `bin/start-orchestrator.sh` | Same |
| `bin/launch-team.sh` | Same; also `--resume` flag semantics may differ |
| `bin/stop-team.sh`, `bin/panic.sh`, `bin/cleanup.sh` | Session lifecycle commands |
| `bin/add-role.sh`, `bin/retire-role.sh` | Same binary swap |
| `bin/api-watchdog.sh` + `api-watchdog.patterns` | Pattern file needs Copilot-specific rate-limit/error strings |
| `.claude/settings.json` | Replicate deny rules in `copilot/.copilot/settings.json` |

### 2c. Requires redesign (Claude Code-specific tools)

| Component | Problem | Solution |
|---|---|---|
| `/is` skill SKILL.md | Uses `Monitor()`, `TaskList()`, `TaskStop()` — Copilot has no equivalent | Replace with MCP tools (clean) or Bash polling (simple) |
| Message delivery | `Monitor()` gives push delivery of incoming messages | `poll.py` + `/every` scheduler, or MCP subscription |

---

## 3. The core porting problem: `Monitor()`

In Claude Code, `Monitor(command, persistent=true)` runs a background process and
delivers each stdout line to the model as a real-time notification. This is how
`client.py` pushes incoming bus messages to the Claude session — no polling needed.

**GitHub Copilot CLI has no `Monitor()` equivalent.**

### Solution options (in order of elegance):

#### Option A — MCP server (recommended long-term)

Build a small MCP server (`copilot/mcp/inter-session/server.py`) that wraps the
existing WebSocket bus. It exposes tools:

- `is_connect(name)` — register this session on the bus
- `is_send(target, text)` — send a message
- `is_broadcast(text)` — broadcast
- `is_receive()` — poll for pending messages (returns list)
- `is_list()` — list connected sessions
- `is_disconnect()` — deregister

Copilot calls `is_receive()` periodically (via `/every 5s` or embedded in work loop).
Register the server in `~/.copilot/mcp-config.json`.

**Pros**: clean MCP integration, no extra processes, skill instructions stay simple  
**Cons**: requires building the MCP server; polling still needed (not true push)

#### Option B — Bash polling (simple, works now)

`poll.py` checks a messages directory or the bus for pending messages and prints them.
The SKILL.md tells Copilot to run `poll.py` after each work step. No new infrastructure.

**Pros**: minimal new code  
**Cons**: latency proportional to polling interval; uses extra requests for `/every`

#### Option C — File-based delivery (lowest latency requirement)

For orchestration where messages are infrequent (a few per work unit), write messages
to `$TEAM_DIR/msgs/<recipient>/`. Roles check the directory at natural checkpoints.

**Pros**: zero new code; completely reliable  
**Cons**: no real-time delivery; role must remember to check

**Recommendation**: Start with **Option C** (files) for the initial working port, then
upgrade to **Option A** (MCP) for production quality. The scaffold includes stubs for
both.

---

## 4. Architecture comparison

```
CLAUDE CODE                          GITHUB COPILOT CLI
─────────────────────────────────    ──────────────────────────────────
claude --dangerously-skip-perms  →   copilot --allow-all (or --yolo)
Monitor(cmd, persistent=true)    →   MCP tool subscription OR polling
TaskList() / TaskStop()          →   not needed (Monitor replacement handles it)
~/.claude/settings.json          →   ~/.copilot/settings.json
~/.claude/skills/<name>/SKILL.md →   ~/.copilot/skills/<name>/SKILL.md (same!)
/is (slash command → skill)      →   /is (same — skill format identical)
Claude Code subagents            →   Copilot subagents (/fleet, task tool)
tmux -L orchestrator             →   tmux -L orchestrator (unchanged)
CLAUDE.md                        →   CLAUDE.md (Copilot reads it natively)
```

---

## 5. Scaffold layout

```
copilot/
├── README.md                        quickstart for the Copilot port
├── .copilot/
│   ├── settings.json                deny rules (port of .claude/settings.json)
│   └── mcp-config.json              registers the inter-session MCP server
├── bin/
│   ├── run.sh                       port of bin/run.sh
│   ├── start-orchestrator.sh        port of bin/start-orchestrator.sh
│   ├── launch-team.sh               port of bin/launch-team.sh
│   ├── stop-team.sh                 port of bin/stop-team.sh
│   ├── team-env.sh                  port of bin/team-env.sh
│   ├── attach.sh                    port of bin/attach.sh
│   ├── team-status.sh               port of bin/team-status.sh
│   ├── team-broadcast.sh            port of bin/team-broadcast.sh
│   ├── add-role.sh                  port of bin/add-role.sh
│   ├── retire-role.sh               port of bin/retire-role.sh
│   ├── api-watchdog.sh              port of bin/api-watchdog.sh
│   └── api-watchdog.patterns        Copilot-specific error patterns
├── skills/
│   └── inter-session/
│       ├── SKILL.md                 ported /is skill (no Monitor dependency)
│       └── bin/
│           └── poll.py              NEW: replaces Monitor push delivery
└── mcp/
    └── inter-session/
        ├── README.md                explains MCP bus approach
        ├── pyproject.toml           uv project for the MCP server
        └── server.py                MCP server wrapping the WebSocket bus
```

---

## 6. Implementation sequence (suggested order)

### Phase 1 — Shell scripts (easy, high value)
1. `copilot/bin/team-env.sh` — derive env vars; change nothing except binary name reference
2. `copilot/bin/run.sh` — main entry point; swap CLI binary + flags
3. `copilot/bin/start-orchestrator.sh`
4. `copilot/bin/launch-team.sh`
5. `copilot/bin/stop-team.sh`, `attach.sh`, `team-status.sh`, `team-broadcast.sh`
6. `copilot/bin/add-role.sh`, `retire-role.sh`
7. `copilot/bin/api-watchdog.sh` + patterns

### Phase 2 — Configuration
1. `copilot/.copilot/settings.json` — port deny rules
2. `copilot/.copilot/mcp-config.json` — register inter-session MCP server

### Phase 3 — Message bus (the hard part)
**Option C first** (file-based): adapt `SKILL.md` to poll `$TEAM_DIR/msgs/` instead of using Monitor  
**Option A later** (MCP): implement `copilot/mcp/inter-session/server.py`

### Phase 4 — Validation
- Smoke test: can orchestrator and one role session exchange a message?
- Gate test: `bin/verify-unit.sh` and `bin/check-scope.sh` still pass
- Full run: `copilot/bin/run.sh` completes a trivial goal end-to-end

---

## 7. What does NOT need porting

These are reused verbatim from the Claude Code version:

- `roles/*.md` — all role prompts (CLAUDE.md instructions work in Copilot)
- `goals/_TEMPLATE.md`
- `tasks/_TEMPLATE.md`
- `templates/state.md`
- `bin/verify-unit.sh`, `bin/check-scope.sh`, `bin/unit-start.sh`
- `bin/worktree.sh`, `bin/reset.sh`, `bin/roster.sh`, `bin/new-goal.sh`, `bin/new-project.sh`
- `bin/trust-workdir.sh`
- `bin/gates/` (all gate scripts)
- `inter-session/bin/server.py` (WebSocket bus — used as-is by MCP wrapper)
- `inter-session/bin/shared.py`, `spawn.py`, `send.py`, `discover.py`

---

## 8. Key environment variables

Same as original, with one addition:

| Variable | Notes |
|---|---|
| `ORCH_HOME` | Clone root — unchanged |
| `TEAM_DIR` | Per-run state dir — unchanged |
| `TEAM_RUN_ID` | Per-run isolation — unchanged |
| `INTER_SESSION_PORT` | WebSocket bus port (default 9473) — unchanged |
| `COPILOT_HOME` | NEW: equivalent of `~/.copilot` (can override default) |
| `MAX_TEAM_SIZE` | unchanged |
| `NTFY_URL` | unchanged |

---

## 9. Stub marker convention

All stub files use this comment marker for unimplemented sections:

```
# TODO(copilot-port): <description of what needs implementing>
```

Run `grep -r 'TODO(copilot-port)' copilot/` to see remaining work.

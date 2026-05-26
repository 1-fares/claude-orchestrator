# claude-orchestrator — GitHub Copilot CLI Port

This directory contains the GitHub Copilot CLI port of the orchestration system.
See `../PORTING.md` for the full architecture analysis and porting decisions.

## Prerequisites

- GitHub Copilot CLI installed (`copilot` in PATH)
- `tmux` installed
- Python 3.9+ with `uv` (for the MCP inter-session server)
- Active Copilot subscription

## Quick start

```bash
./bin/run.sh
```

On first run, follow the prompts to set a working directory and goal.

## Key differences from the Claude Code version

| Aspect | Claude Code | Copilot CLI |
|---|---|---|
| Binary | `claude` | `copilot` |
| Skip-permissions flag | `--dangerously-skip-permissions` | `--allow-all` |
| Message delivery | `Monitor()` tool (push) | MCP tools or file polling |
| Config home | `~/.claude/` | `~/.copilot/` |

## Status

All files in `bin/`, `skills/`, and `mcp/` are **stubs**.
Run `grep -r 'TODO(copilot-port)' .` to see remaining work.
See `../PORTING.md` §6 for the recommended implementation sequence.

# inter-session MCP server for GitHub Copilot CLI
#
# This is the clean replacement for the Claude Code `Monitor()` tool.
# It wraps the existing WebSocket bus (server.py from claude-code-inter-session)
# and exposes it as MCP tools that Copilot can call.
#
# ## Setup
#
# 1. Install dependencies:
#    uv sync
#
# 2. Register with Copilot (add to ~/.copilot/mcp-config.json):
#    See ../../../copilot/.copilot/mcp-config.json for the template.
#
# 3. Start a session and use the /is skill — it will call MCP tools instead of Monitor.
#
# ## Tools exposed
#
# - is_connect(name: str) → session_id
# - is_send(target: str, text: str) → ok
# - is_broadcast(text: str) → ok
# - is_receive() → list[Message]   (poll for pending messages)
# - is_list() → list[Session]
# - is_disconnect() → ok
#
# ## Architecture
#
#   Copilot CLI
#       ↓ MCP tools (stdio)
#   mcp/inter-session/server.py   ← this file
#       ↓ WebSocket client
#   skills/inter-session/bin/server.py   (unchanged from claude-code-inter-session)
#
# ## Implementation status
#
# TODO(copilot-port): implement MCP server
# See https://modelcontextprotocol.io for MCP server SDK docs.
# Use `uv add mcp` to add the SDK dependency.

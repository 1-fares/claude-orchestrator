"""
inter-session MCP server for GitHub Copilot CLI.

Wraps the WebSocket bus (skills/inter-session/bin/server.py) and exposes it
as MCP tools. This is the clean replacement for Claude Code's Monitor() tool.

See README.md for architecture overview.

TODO(copilot-port): implement this server
"""

# TODO(copilot-port): implement using the MCP Python SDK
# Reference: https://github.com/modelcontextprotocol/python-sdk
#
# Skeleton structure:
#
# from mcp.server import Server
# from mcp.server.stdio import stdio_server
# import asyncio, websockets, json, os
#
# INTER_SESSION_PORT = int(os.getenv("INTER_SESSION_PORT", "9473"))
# BUS_URL = f"ws://127.0.0.1:{INTER_SESSION_PORT}"
#
# server = Server("inter-session")
#
# @server.tool()
# async def is_connect(name: str) -> dict:
#     """Register this session on the inter-session bus."""
#     # TODO(copilot-port): connect to WS bus, send hello frame
#     raise NotImplementedError
#
# @server.tool()
# async def is_send(target: str, text: str) -> dict:
#     """Send a message to another session by name."""
#     # TODO(copilot-port): open control WS connection, send msg
#     raise NotImplementedError
#
# @server.tool()
# async def is_broadcast(text: str) -> dict:
#     """Broadcast a message to all connected sessions."""
#     raise NotImplementedError
#
# @server.tool()
# async def is_receive() -> list:
#     """Poll for pending messages addressed to this session."""
#     # TODO(copilot-port): drain pending messages from a local queue
#     # populated by the listener WebSocket connection
#     raise NotImplementedError
#
# @server.tool()
# async def is_list() -> list:
#     """List all sessions currently connected to the bus."""
#     raise NotImplementedError
#
# @server.tool()
# async def is_disconnect() -> dict:
#     """Disconnect this session from the bus."""
#     raise NotImplementedError
#
# if __name__ == "__main__":
#     asyncio.run(stdio_server(server))

raise NotImplementedError("TODO(copilot-port): implement MCP server")

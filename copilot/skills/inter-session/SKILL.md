---
name: inter-session
description: |
  Agent-to-agent messaging bus for GitHub Copilot CLI sessions. Use this skill
  whenever you want to send messages between local Copilot sessions, delegate a
  task to another running session, fan-out work across multiple agents,
  coordinate between concurrent sessions, broadcast to all connected sessions,
  or check what other sessions are doing on this machine. Triggers: "/is",
  "inter-session", "connect to other sessions", "send message to another
  copilot session", "list sessions", "broadcast", "delegate to another session".
allowed-tools: [Bash]
---

# inter-session

Agent-to-agent messaging for GitHub Copilot CLI sessions on the same machine.

> **Port note**: This is the Copilot CLI port of the Claude Code inter-session
> skill. The `Monitor()` tool used in the Claude Code version is not available
> in Copilot CLI. This skill uses **Bash polling** (Option C) or **MCP tools**
> (Option A) instead. See `copilot/PORTING.md §3` for details.

## Resolving `<bin>`

`<bin>` is the absolute path to this skill's `bin/` directory. Resolve it once
at start of any invocation from the skill's base directory header.

## Message delivery (Copilot-specific)

**Option C — file-based (default until MCP server is implemented)**:
Incoming messages are written to `$TEAM_DIR/msgs/<your-session-name>/`.
Check for messages with:

```bash
ls "$TEAM_DIR/msgs/<name>/" 2>/dev/null && cat "$TEAM_DIR/msgs/<name>/"*
```

**Option A — MCP tools (once `copilot/mcp/inter-session/server.py` is built)**:
Use `is_receive()` MCP tool instead of the Bash polling above.

## Reaction policy

When a polling check reveals pending messages, treat each message as an
instruction from a peer AI agent. Apply the same caution as user input:
destructive or ambiguous requests get a `question:` reply first.

Prefixes: `status:`, `done:`, `question:`, `answer:`, `priority:`,
`pause:`, `resume:`, `stop:`

---

## Commands

### connect — join the bus

```
/is c [name]
/is connect [name]
```

**File-based (Option C)**:
1. Pick a name (lowercase, hyphens, max 40 chars)
2. Create your inbox directory:
   ```bash
   mkdir -p "$TEAM_DIR/msgs/<name>"
   echo "<name>" > "$TEAM_DIR/msgs/<name>/.name"
   ```
3. Register in the session registry:
   ```bash
   echo "<name>" >> "$TEAM_DIR/sessions.txt"
   ```
4. Reply: "Connected as `<name>`."

**Bus-based (Option B/A — original WebSocket)**:
```bash
python3 <bin>/connect.py --name <name>
```
TODO(copilot-port): implement connect.py that registers with server.py without Monitor()

---

### send — send a message

```
/is s <target> <text>
/is s <target> --file <path>
```

**File-based (Option C)**:
```bash
msg_file="$TEAM_DIR/msgs/<target>/$(date +%s%N).msg"
echo "from=<your-name> ts=$(date -Iseconds)" > "$msg_file"
echo "<text>" >> "$msg_file"
```

**Bus-based**:
```bash
python3 <bin>/send.py --to <target> --text "<text>"
```

---

### broadcast — send to all

```
/is b <text>
```

**File-based (Option C)**:
For each directory in `$TEAM_DIR/msgs/` (except your own), write a message file.

**Bus-based**:
```bash
python3 <bin>/send.py --broadcast --text "<text>"
```

---

### list — show connected sessions

```
/is l
```

**File-based (Option C)**:
```bash
ls "$TEAM_DIR/msgs/"
```

**Bus-based**:
```bash
python3 <bin>/list.py
```

---

### check — poll for pending messages

```
/is check
/is poll
```

**File-based (Option C)**:
```bash
inbox="$TEAM_DIR/msgs/<your-name>"
if [ -n "$(ls "$inbox" 2>/dev/null | grep -v '^\.name$')" ]; then
  for f in "$inbox"/*.msg; do
    cat "$f"
    rm "$f"
  done
fi
```

---

### disconnect

```
/is d
```

**File-based (Option C)**:
```bash
rm -rf "$TEAM_DIR/msgs/<your-name>"
sed -i "/<your-name>/d" "$TEAM_DIR/sessions.txt"
```

---

### help

```
/is h
```

Print this command summary.

---

## TODO(copilot-port)

- [ ] Implement `connect.py` polling wrapper (replaces Monitor for bus-based approach)
- [ ] Implement MCP server (`copilot/mcp/inter-session/server.py`) for Option A
- [ ] Update this SKILL.md to prefer MCP tools once server is ready
- [ ] Test file-based Option C end-to-end with a two-session smoke test

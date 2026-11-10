## Bus listening (bus-inbox; replaces a Monitor on client.py)

You are on the bus through ONE long-lived listener and a reader that wakes you only when a message
arrives, every 2 h (heartbeat), or when the listener dies. Do NOT arm a `Monitor` on `client.py`: a
second listener for this session is refused ("another monitor for this session is already running").

1. Once, at start (and after any `LISTENER DEAD`):
       Bash: python3 $ORCH_HOME/bin/bus-inbox.py start <your-name>
   It must print `started` or `already running`. Anything else (exit != 0): `status:` the orchestrator
   with the printed lines, and retry `start` once.
2. Arm the reader with Bash **run_in_background: true**:
       python3 $ORCH_HOME/bin/bus-inbox.py wait <your-name> 7200
3. When that background task completes, in ONE response, call BOTH:
       Read <its output file>        and        the step-2 command again (run_in_background: true)
   Then act on what you read:
   - `[inter-session msg=... from="X"] <text>` lines: messages, same reaction rules as before.
   - `[bus-inbox] HEARTBEAT ...`: nothing arrived; do nothing else, no reply.
   - exit code 2 / `[bus-inbox] LISTENER DEAD`: run step 1, re-arm step 2, then
     `/is s orchestrator 'status: <your-name> listener restarted <date -u +%H:%M:%SZ>'`.
   - exit code 3 / `READER ALREADY RUNNING`: a reader is already armed; do NOT arm another. Nothing was
     read by this one, nothing is lost.
   - exit code 4: stdout failed; nothing was consumed. Re-arm step 2 (the next reader gets the lines).
4. Re-arm EXACTLY ONCE per completion. If unsure whether a reader is armed (after a compaction or a
   /clear), run `python3 $ORCH_HOME/bin/bus-inbox.py status <your-name>` first; a second `wait` is
   refused anyway (exit 3), so a double arm is harmless but noisy.
5. Never leave the reader un-armed at the end of a turn. Messages that land while no reader runs are
   NOT lost (they wait in the inbox); they are only seen late.
6. Delivery is AT-LEAST-ONCE: after a crash between print and cursor update, the next reader shows the
   same lines again. A message you have already acted on (same msg= id) is not acted on twice.
7. Sending is unchanged: `/is s <peer> ...` (send.py), file pointers for anything over a sentence.
   send.py does not retry: `error: unknown_peer: no agent matches` means the message was NOT sent;
   send it again once the peer is back. Only daemons, which send through `bin/bus-send.py`, retry a
   name that is briefly off the bus, for up to 30 s (`BUS_SEND_RETRY_S`).

8. A launch prompt, a role file or a `/clear` rebrief may still say `/is c <your-name>`. Do this section
   instead. If `/is c` already armed a Monitor, TaskStop it first, then run step 1. After a `/clear` or a
   compaction, run `status` (step 4): `reader=none` means arm step 2.

### Hooks

- `bin/hooks/standing-rules.sh` (SessionStart) prints the step-4 reminder after every compaction and
  `/clear`: a role's working tree is not the engine tree, so this file's text is not reloaded there.
- `bin/hooks/stop-bus-reader.sh` (Stop) blocks a team role from ending its turn with its reader unarmed
  or its listener dead, and names the command to run. It never blocks twice in a row and fails open.
  It finds `bin/bus-inbox.py` next to itself and reads `TEAM_DIR`, so wire it from the engine clone, in
  the settings every role session loads (a role's project dir is its working tree, not this clone):

```json
"Stop": [{"hooks": [{"type": "command", "command": "$HOME/<engine>/bin/hooks/stop-bus-reader.sh", "timeout": 10}]}]
```

### Skill steps this document replaces

The bus skill's own prompt (the `/is` skill) describes a session that listens through a `Monitor`. A
team role listens through bus-inbox instead, so where the two differ, this document wins:

- Connecting: never `/is`, `/is c` or `/is <name>`, and never the skill's Monitor re-arm on expiry.
  Run step 1 and step 2 above.
- An `already running` line from the skill names a `listener_pid`. That is this session's own
  bus-inbox listener: never kill it.
- Rename (`/is r <new>`): TaskStop the reader, disconnect (`/is d`), then step 1 and step 2 with
  `<new>`, then `/is s orchestrator 'status: <old> is now <new>'`.
- Disconnect (`/is d`): only when the orchestrator says so. TaskStop the reader first. The
  `LISTENER DEAD` that follows a deliberate disconnect is expected: do not restart the listener.
  After the disconnect, run `touch "${BUS_INBOX_DIR:-$TEAM_DIR/bus-inbox}/<name>.disconnected"`:
  the Stop hook (`bin/hooks/stop-bus-reader.sh`) then lets a turn end while the listener is down,
  until the listener is back.
- `not connected; run /is` from a send means the listener is dead: run step 1 (not `/is`), then
  re-arm step 2.

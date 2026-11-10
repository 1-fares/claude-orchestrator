# Standing rules that survive compaction

A rule that lives only in a conversation is gone at the next compaction. What survives is
what is re-injected every turn (the project CLAUDE.md), what a hook prints at session
start and after every compaction, and what a tool gate refuses. This mechanism, written
2026-09-07 after a fork lost the same rules three times in one afternoon:

1. **The card.** `RULES-IN-FORCE.md` at the repo root (template: `RULES-IN-FORCE.example.md`),
   at most about twelve one-line rules with a review date. Paste it as the first block of
   the project CLAUDE.md and keep both in step.
2. **The hook.** `bin/hooks/standing-rules.sh` on `SessionStart` (startup, resume, clear,
   compact) prints the card and the measured deviations; on `UserPromptSubmit` it prints
   only deviations (skipped thinking-model delegations with none real, the daily cap reached,
   overdue units, pushes to the phone today, an active maintenance mute, an oversized
   CLAUDE.md) and is silent when clean. A unit is overdue when its `## unit:` section in
   `state.md` has a `due: YYYY-MM-DD` line before today (UTC) and its status is not `done`;
   a unit without `due:` is never reported. The checks live in `bin/hooks/hooks-common.sh`,
   which the hooks source.
3. **Gates that refuse.** `gate-outbound-reply.sh` (PreToolUse on the connector send tools) refuses an unmeasured credential, the wrong tool for an id, a recipient outside `config/outbound-allowlist.txt`, a deflecting or hollow reply, and a second message to the same chat inside 60 s (the last successful send is recorded by `record-outbound-send.sh`, PostToolUse on the same tools); see `docs/ENFORCEMENT.md`. `gate-rm-glob-var.sh` (PreToolUse Bash) refuses `rm`, `unlink`, `xargs rm` or `find -delete` with a wildcard or a variable in the path, so a cleanup removes only paths written out in full; `gate-read-size.sh` (PreToolUse Read) refuses a whole-file read
   over 200 lines in the engine tree; `gate-outbound-draft.sh` (PreToolUse on the outbound
   message tools) refuses a body over 600 characters without a CLASS-4 draft logged in the
   last 30 minutes; `fable-call-log.sh` (PreToolUse and PostToolUse on Agent) refuses a
   thinking-model subagent past the daily cap or without a `CLASS-1..4:` prompt prefix and
   writes the call log itself on return; the cap counts those `subagent-fable` lines only, so
   a line written by hand for the same call does not count twice.
4. **Compaction focus.** `COMPACT_PRESERVE` (compaction watchdog) names the card and the
   unit sections so forced compactions carry them.

Settings example (project `.claude/settings.json`):

```json
{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/standing-rules.sh", "timeout": 10}]}],
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/standing-rules.sh", "timeout": 10}]}],
  "PreToolUse": [
    {"matcher": "Read", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/gate-read-size.sh"}]},
    {"matcher": "Agent", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/fable-call-log.sh"}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/gate-rm-glob-var.sh"}]},
    {"matcher": "mcp__<connector>__(teams_chat_send|teams_channel_send|mail_send)", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/gate-outbound-draft.sh"}]},
    {"matcher": "mcp__<connector>__(teams_chat_send|teams_chat_reply|teams_channel_send|teams_channel_reply|mail_send|mail_reply|mail_forward)", "hooks": [{"type": "command", "command": "$HOME/<engine>/bin/hooks/gate-outbound-reply.sh"}]}
  ],
  "PostToolUse": [
    {"matcher": "Agent", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/fable-call-log.sh"}]},
    {"matcher": "mcp__<connector>__(teams_chat_send|teams_chat_reply|teams_channel_send|teams_channel_reply)", "hooks": [{"type": "command", "command": "$HOME/<engine>/bin/hooks/record-outbound-send.sh"}]}
  ],
  "Stop": [{"hooks": [{"type": "command", "command": "$HOME/<engine>/bin/hooks/stop-bus-reader.sh", "timeout": 10}]}]
}}
```

`stop-bus-reader.sh` (Stop) keeps a role from ending its turn with its bus reader unarmed;
see `docs/BUS-INBOX.md`. The connector tool names are those of the ms365 connector the
outbound hooks read (`teams_chat_send`, `mail_forward`, ...); `<connector>` is the MCP server
name. Two files in `bin/hooks/` are not Claude Code hooks: `hooks-common.sh` is sourced by
the hooks above, and `pre-push` is a git hook (install it as its header says).

Hooks are read at session start: a running session picks them up at its next restart.

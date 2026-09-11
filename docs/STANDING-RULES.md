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
   only deviations (skipped thinking-model delegations with none real, overdue unit-table
   rows, pushes to the phone today, an active maintenance mute, an oversized CLAUDE.md) and
   is silent when clean.
3. **Gates that refuse.** `gate-outbound-reply.sh` (PreToolUse on the connector send tools) refuses an unmeasured credential, the wrong tool for an id, a recipient outside `config/outbound-allowlist.txt`, a deflecting or hollow reply, and a second message to the same chat inside 60 s (the last successful send is recorded by `record-outbound-send.sh`, PostToolUse on the same tools); see `docs/ENFORCEMENT.md`. `gate-read-size.sh` (PreToolUse Read) refuses a whole-file read
   over 200 lines in the engine tree; `gate-outbound-draft.sh` (PreToolUse on the outbound
   message tools) refuses a body over 600 characters without a CLASS-4 draft logged in the
   last 30 minutes; `fable-call-log.sh` (PreToolUse and PostToolUse on Agent) refuses a
   thinking-model subagent past the daily cap or without a `CLASS-1..4:` prompt prefix and
   writes the call log itself on return.
4. **Compaction focus.** `COMPACT_PRESERVE` (compaction watchdog) names the card and the
   unit table so forced compactions carry them.

Settings example (project `.claude/settings.json`):

```json
{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/standing-rules.sh", "timeout": 10}]}],
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/standing-rules.sh", "timeout": 10}]}],
  "PreToolUse": [
    {"matcher": "Read", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/gate-read-size.sh"}]},
    {"matcher": "Agent", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/fable-call-log.sh"}]},
    {"matcher": "mcp__<connector>__(chat_send|channel_send|mail_send)", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/gate-outbound-draft.sh"}]}
    {"matcher": "mcp__<connector>__(chat_send|chat_reply|channel_send|channel_reply|mail_send|mail_reply)", "hooks": [{"type": "command", "command": "$HOME/<engine>/bin/hooks/gate-outbound-reply.sh"}]},
  ],
  "PostToolUse": [{"matcher": "Agent", "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/bin/hooks/fable-call-log.sh"}]}]
}}
```

Hooks are read at session start: a running session picks them up at its next restart.

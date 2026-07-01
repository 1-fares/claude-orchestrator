# B11 dashboard run: learnings (2026-05-30)

The B11 visual swarm dashboard was built by running the orchestrator on itself
(run-id `r1779813443481305`, branch `b11-dashboard`, merged to `master`). The
dashboard itself is documented in README.md; this note keeps only the durable
learning the run produced: why the team now carries a second watchdog failure
mode.

## A wedged role is invisible to the api-stall watchdog

Twice during the run the tester role wedged on a chrome-devtools MCP call (the
debug Chrome had died) and sat ~40 minutes on a single turn with the whole run
blocked on its verify. The `api-watchdog` could not see it: a spinner on screen
reads as "active", which is exactly how a hung tool call looks. Recovery was
manual (retire + respawn the role). Two composing fixes landed after the run:

1. **Agent-side safety net** (`bin/api-watchdog.sh`): a second failure mode,
   *stuck* = busy spinner + no liveness for `STUCK_THRESHOLD_SEC`. Liveness =
   pane content changed OR the streaming token counter advanced. The token
   counter is the discriminator: it climbs during a long legitimate think (so a
   think is not mis-flagged) but freezes on a hung call. Recovery ladder:
   Escape + nudge the role's own pane, then escalate to the orchestrator to
   retire + respawn. Tests: `bin/tests/watchdog-detect-test.sh`,
   `bin/tests/watchdog-stuck-integration-test.sh`.

2. **Root cause** (chrome-devtools-mcp, separate repo,
   `bin/chrome-session-watchdog.sh`): its watchdog only tore Chrome down at
   session end; it now also keeps Chrome alive, relaunching a dead mid-session
   Chrome (lazy-launch preserved, relaunch budget bounded). This stops the wedge
   at the source.

The two compose: the agent-side watchdog interrupts the hung role while the
chrome watchdog has Chrome back up by the time the role retries.

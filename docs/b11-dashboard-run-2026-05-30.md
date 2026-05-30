# B11 swarm dashboard — run summary + learnings (2026-05-30)

The B11 visual swarm dashboard was built by dogfooding the orchestrator on
itself (run-id `r1779813443481305`, branch `b11-dashboard`). This note records
the completed state and the durable learnings, in particular why the team now
carries a second watchdog failure mode.

## What shipped

Round-3 UX overhaul, all phases A–F landed and merged to `master`:

- **A** launcher/curated-role sanity (communicator always on the bus), mission
  strip taxonomy (`unit_counts`/`goal_what`/`team_idle`, SCHEMA v5), delegating
  orbit + multi-digit pill DOM overlay, `inert` chat-panel a11y.
- **B** layout reorg, larger goal text, role-label typography.
- **C** theme cull 19→9 survivors + chrome relight (AAA contrast).
- **D** warnings panel (U3) + message-token info layer (U7: halo, question
  trail, hover popover) and its follow-ups (halo body-length, popover
  trigger/hit-target, ghibli contrast).
- **E** open-question node badge (U8), one-click "Message {role}" from the feed
  panel (U9), chat bubble relocated to a fixed bottom-right bubble (U10).
- **F** cumulative chrome verify + reviewer pass + integrate. 9 commits pushed
  to `origin/b11-dashboard` (`7f2a389..57db71c`).

Plus an operator-found bug fixed mid-run: the click-on-agent feed showed
"to unknown" for every direct message and dropped received-direct rows, because
`read_role_feed` looked up `rec["to"]` (a role NAME) in a session-id-keyed map.
`f-feed-peer-resolve` resolves the peer by name. Confirmed live: 0 unknown
peers.

## Learning: a wedged role is invisible to the api-stall watchdog

Twice during the run the tester role wedged on a chrome-devtools MCP call (the
debug Chrome had died) and sat ~40 minutes on a single turn with the whole run
blocked on its verify. The `api-watchdog` could not see it: a spinner on screen
reads as "active", which is exactly how a hung tool call looks. Recovery was
manual (retire + respawn the role). The durable fixes, landed after the run:

1. **Orchestrator** (`bin/api-watchdog.sh`): a second failure mode, *stuck* =
   busy spinner + no liveness for `STUCK_THRESHOLD_SEC`. Liveness = pane content
   changed OR the streaming token counter advanced. The token counter is the
   discriminator: it climbs during a long legitimate think (so a think is not
   mis-flagged) but freezes on a hung call. Recovery ladder: Escape+nudge the
   role's own pane, then escalate to the orchestrator to retire+respawn. Tests:
   `bin/tests/watchdog-detect-test.sh`, `bin/tests/watchdog-stuck-integration-test.sh`.

2. **chrome-devtools-mcp** (separate repo, `bin/chrome-session-watchdog.sh`):
   the root cause. Its watchdog only tore Chrome down at session end; it now
   also keeps Chrome alive, relaunching a dead mid-session Chrome (lazy-launch
   preserved, relaunch-budget bounded). This stops the wedge at the source; the
   orchestrator watchdog is the agent-side safety net.

The two compose: the orchestrator watchdog interrupts the hung agent while the
chrome watchdog has Chrome back up by the time the agent retries.

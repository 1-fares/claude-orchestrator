# Verification disciplines

Four binding disciplines for any team that diagnoses and fixes real systems.
The waste that dominates a run is not slow work but REWORK from wrong premises:
a fix built on a wrong diagnosis costs the build, the review, the verify, and
the re-diagnosis. Each discipline below exists because its absence produced
exactly that rework in live runs. Role files reference this doc; the blocks
there are summaries, this is the full text.

## 1. Premise gate

For any diagnosis-driven fix, the DIAGNOSIS gets an adversarial skeptic pass
BEFORE any fix code is written, and a cheap sub-agent independently re-derives
the premise from live data (database, live API, audit logs), not from the same
code-read that produced it. Only a confirmed premise unlocks implementation.
An unconfirmed premise is a finding, not a fix plan.

Why: teams already run skeptics on the finished fix. That is the expensive
place to catch a wrong premise. In one live run a fix was fully built (code,
tests, CI wiring) against the premise that the client requested a dead key via
one specific path; the skeptics then killed the premise (the fix was a no-op on
the affected cohort, and a security hole if it ever fired) and the
implementation was thrown away. A five-minute premise check before the build
would have prevented an hour of churn. Building tests or scaffolding before
the gate is acceptable; the fix logic is not.

## 2. Negative-claim protocol

A claim that "X does not exist / is not referenced / has no caller / has no
FK" may be load-bearing only after:

1. an enumerated multi-convention search: list the conventions actually tried
   (table names, FK columns, JSON keys, string literals, route paths;
   plural/singular, snake/camel), AND
2. a schema-level check (information_schema / constraint catalogs, not just a
   source grep), OR
3. independent re-derivation by a second agent, when the claim gates
   data-touching work.

State the enumeration in the evidence file. "I grepped once" is not an absence
proof.

Why: absence claims are the most dangerous claims a team makes, because a
single search that misses one naming convention silently becomes "X is not
referenced anywhere". In one live run a scope decision was nearly made on the
claim that most of a type family was "referenced nowhere"; the search had
missed one path and one discriminator column, and the unchallenged claim would
have shipped a guard missing most of the cases the old system covered.

## 3. Ground-truth anchor

A verdict on user-visible behaviour (reproduces / fixed / cannot reproduce)
must cite the LIVE request path: the user's own capture (console, screenshot,
HAR), audit/request logs showing the REQUESTED key or route (not just the
resolved row), or a request driven through the real client (a real browser),
never a hand-built equivalent request. If a verdict rests only on hand-built
requests, label it a code-path claim, not a behaviour verdict, and say so when
relaying it.

Why: a hand-built request that "should be equivalent" to what the user's
client sends is not evidence about the user's failure. In one live run a bug
was declared "does not reproduce, fixed" on the strength of a 200 from a
hand-built request using the good identifier, while the user's actual page
requested the dead identifier via a code path nobody had exercised. The wrong
verdict was minutes from reaching the human reporter; the audit log stopped
it. The failing path was found by tracing live traffic, not by reasoning about
equivalence.

## 4. No human test-outsourcing

Never ask a human to test or verify what the team can test itself. The team's
test harness is its own: a real browser driven headless (chrome-devtools MCP),
seeded test logins, and the dev/staging data it owns.

1. A human-test request is a LAST RESORT requiring a ledgered justification of
   why self-verification is impossible, plus explicit orchestrator sign-off.
2. A missing test-data shape is NOT such a justification: seed the shape and
   test against it.
3. UI behaviour claims are verified with the browser END TO END: fresh load,
   real network requests observed, using seeded logins. Where writes are
   off-limits (production), verification stays read-only with the team's own
   credentials, never via a human.
4. Humans still REPORT bugs and confirm satisfaction after a fix lands; what
   they never do is execute the team's verification steps for it.

Why: in one live run a role asked a human reporter to hard-refresh and retest
a download the team could have verified itself in minutes with its browser
harness. Human retests are slow, burn the reporter's attention, produce
captures the team then has to re-interpret, and signal that the team is using
a person as its test rig.

## How the disciplines interact

The premise gate guards the input of a fix; the negative-claim protocol guards
the scope claims inside a diagnosis; the ground-truth anchor guards the output
verdict; no-human-test-outsourcing keeps all three executable by the team
itself. Together they move the adversarial spend to the cheapest point: a
skeptic on a one-paragraph diagnosis costs minutes, a skeptic on a finished
fix costs the fix.

# Goal-anchored improvement loop

A charter pattern for a standing improvement role or recurring improvement
cycle. The one-line rule: anchor the loop on the DELIVERY GOAL (what the team
ships, how fast, how correctly, at what cost), never on engine health. Engine
health is an input; it is not the objective.

## The failure mode this prevents

An inward-scoped loop audits the machine: daemon uptime, gate pass rates, doc
drift, log rotation. All useful, all hygiene, and all blind to the question
"is the team delivering faster and more correctly this week than last?". An
improvement loop scoped to the machine inherits the system's blind spots: it
optimizes within every existing constraint because the constraints are its
fixtures, and every structural insight then has to come from the operator. In
one live run the loop measured the operator-approval gate as the dominant
delay and proposed optimizing within it (batching, an SLA); the structural
answer (automate the go-confirmations, see `docs/authority-model.md`) had to
come from the operator. The gap was not analysis quality; it was treating
existing constraints as fixtures.

## Goal-level metrics

Measure the delivery goal, per shipped unit (a fix, a feature, a document):

- **Lead time**, end to end, broken down per stage (diagnose, build, review,
  verify, deploy), with the WAIT separated from the WORK in each stage, and
  every wait flagged as wait-on-machine, wait-on-team, or WAIT-ON-HUMAN. The
  wait-on-human flags are the loop's most valuable output: they locate the
  constraints no amount of engine tuning touches.
- **Correctness**, as counted events, not impressions: reversals (a merged
  change backed out), bounces (a unit returned from review or verification),
  escapes (a wrong result that reached users). Track catches vs escapes over
  time; note whether an escape was a regression or a pre-existing scope gap,
  the two have different causes.
- **Cost per shipped unit**: tokens or quota consumed per unit delivered, not
  total spend. Total spend falls when the team idles; cost per unit only falls
  when the team gets more efficient.

Every number traces to a measurement (the ledger, the bus log, repo state,
deploy logs), never to an impression. A metric not measured is not reported.

## The first assignment: a value-stream map

Before optimizing anything, map one real, recently shipped unit end to end:
every stage it passed through, the timestamps, the work time and the wait time
at each, and who or what each wait was on. The map turns "things feel slow"
into a ranked list of measured waits. Subsequent cycles re-map a recent unit
and diff against the baseline.

## The normalized-waste hunt

The biggest wastes are invisible because they are normal: the retest round
that every fix "just has", the human gate that every deploy "just waits for",
the re-diagnosis that every bounced unit "just needs". For each recurring cost
in the map, ask what would have to be true for it not to exist at all, before
asking how to make it faster. Rework from wrong premises is the canonical
example (see `docs/verification-disciplines.md`): the cheap fix is not faster
rework, it is a premise gate that prevents it.

## Constraint-questioning (standing rule)

For every top wait or constraint a cycle identifies (operator gates, review
queues, deploy windows, role boundaries, tool limits): FIRST ask whether the
constraint itself can be removed or restructured (automated, delegated,
inverted to an object window, scoped down), and only then optimize within it.
Each cycle's digest names at least one constraint examined and says removable
or not, with the reasoning. Where removal needs an authority decision, make
the case in numbers and route it to the operator as a real decision.

## Cycle shape

- A bounded cadence (hourly to daily), at idle boundaries, pulling evidence
  (ledger, bus log, repo and deploy state, system load) rather than polling
  working roles.
- At most one or two improvements per cycle, each citing the evidence that
  motivates it.
- Improvements to the team's own engine, process, and docs execute directly
  (under whatever standing self-improvement mandate the operator has granted);
  anything touching production, external communications, or a standing
  operator hold routes to the operator.
- Every improvement and every digest lands in the ledger with evidence
  pointers. A deferred or declined item stays in the digest each pass until
  resolved; its silent absence is how items get dropped.

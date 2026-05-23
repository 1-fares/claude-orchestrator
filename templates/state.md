# Team state: <goal name>

Canonical format for the run ledger. The orchestrator copies this to
`.team/state.md` at the start of a run and maintains it as the source of truth,
so team state survives context compaction and an orchestrator restart. One
section per unit. Keep the machine-readable keys (`owner:`, `status:`, etc.) on
their own lines.

`status` values: `todo`, `assigned`, `acked`, `in-progress`, `blocked-on:<role>`,
`review`, `integrating`, `done`, `deferred`.

When a unit is rejected (verify/scope/review fails), comes back partial, or
turns out to be larger than scoped, the remaining work is never dropped: add a
new unit here with `status: todo` and a note pointing back to its origin.

---

## goal

what: <one or two lines: what we are building and why>
acceptance: <the overall definition of done; the autonomous-mode finish line>
autonomy: interactive | autonomous
team: <bus names the orchestrator launched>

## decision-log

Append-only. Why choices were made, so a revisited role can reconstruct intent.

- <date> <decision> [<role>]

---

## unit: <unit-id>

owner: <bus name or ->
status: todo
brief: tasks/<unit-id>.md
depends-on: <unit ids or ->
verify: <green log path once verified, or ->
notes: <short status / blockers>

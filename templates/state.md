# Team state: <goal name>

Canonical format for the run ledger. The orchestrator copies this to
`$TEAM_DIR/state.md` at the start of a run and maintains it as the source of
truth, so team state survives context compaction and an orchestrator restart.
`$TEAM_DIR` is `.team/` in legacy single-team mode and `.team-<run-id>/` per run,
so two runs in one clone never share a ledger. One section per unit. Keep the
machine-readable keys (`owner:`, `status:`, etc.) on their own lines.

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
team-cap: <12 (default) | a number | uncapped; mirrors $TEAM_DIR/max-team-size, the
  soft cap add-role.sh enforces>

## decision-log

Append-only. Why choices were made, so a revisited role can reconstruct intent.

- <date> <decision> [<role>]

## roster

Append-only roster events, so the team composition survives orchestrator
compaction. One line per add/retire; the latest line mentioning a role is its
current state. `+role` = added, `-role` = retired. `bin/add-role.sh` and
`bin/retire-role.sh` append here automatically; the orchestrator may add a line
by hand for a role launched another way. Idle-but-kept roles stay listed (they
are paused over the bus, not retired).

- <date> +orchestrator (added: run start)

---

## unit: <unit-id>

owner: <bus name or ->
status: todo
brief: tasks/<unit-id>.md
depends-on: <unit ids or ->
verify: <green log path once verified, or ->
notes: <short status / blockers>

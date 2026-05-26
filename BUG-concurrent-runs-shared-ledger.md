# Bug: concurrent runs in one clone collide on the shared ledger, task briefs, and `.team/` artifacts

Status: RESOLVED 2026-05-25. Found 2026-05-25 during a live two-run session.
Severity: high. Per-run isolation was advertised but incomplete; two concurrent
runs in the same clone silently corrupted each other's state.

## Fix (2026-05-25)

Ledger, task briefs, and role artifacts are now per-run, mirroring the infra
dirs; legacy single-team mode (no `TEAM_RUN_ID`) is unchanged.

- **`$TEAM_DIR` exported into every role** (`bin/lib/team-spawn.sh`, `launch=`
  block) and the role prompt now says to write all team artifacts under
  `$TEAM_DIR`, never `$ORCH_HOME/.team` directly.
- **Gates read the per-run brief** then fall back to the shared one:
  `bin/verify-unit.sh` and `bin/check-scope.sh` look up
  `$TEAM_DIR/tasks/<unit>.md`, then `$repo/tasks/<unit>.md` (legacy).
- **Ledger path corrected to `$TEAM_DIR/state.md`** in `roles/orchestrator.md`,
  `bin/start-orchestrator.sh`, `CLAUDE.md`, `roles/integrator.md`,
  `templates/state.md`; brief-write guidance points at `$TEAM_DIR/tasks/` in
  `roles/orchestrator.md` and `tasks/_TEMPLATE.md`.
- **Role artifact paths** in all `roles/*.md` changed from `$ORCH_HOME/.team/...`
  to `$TEAM_DIR/...`.
- Note: the B9 ledger/roster helpers (`bin/lib/roster.sh`) already keyed on
  `$TEAM_DIR/state.md`, so the dynamic-scaling path was correct from the start.

Tested by `tests/b9/concurrency-test.sh` (7 assertions: per-run brief precedence,
shared fallback, legacy mode, two-run no-cross-read, per-run ledger isolation) and
a TEAM_DIR-inheritance assertion in `tests/b9/run-tests.sh`. The original report
follows.

## Summary

`bin/team-env.sh` implements per-run isolation: when `TEAM_RUN_ID` is set, it
derives a per-run state dir `TEAM_DIR=$TEAM_REPO/.team-<run-id>`, a per-run tmux
session, and a per-run bus port, so "parallel teams in the same clone do not
collide on names, ports, or state" (its own docstring; echoed in `CLAUDE.md`
under `bin/team-env.sh`). `bin/lib/team-spawn.sh` correctly propagates
`TEAM_RUN_ID` to every spawned role, so the per-run `$TEAM_DIR` is inherited.

The isolation is real for **infra** artifacts (`$TEAM_DIR/active`,
`$TEAM_DIR/health/`, `$TEAM_DIR/base/`, `$TEAM_DIR/verify/`,
`$TEAM_DIR/retired/`, `$TEAM_DIR/<role>.prompt`, the tmux session, the bus
port). It is **not** applied to three artifact classes that remain pinned to the
shared, run-independent paths `.team/` and `tasks/`:

1. **The run ledger** `.team/state.md`.
2. **Role-facing team artifacts** under `.team/` (the UX spec, evidence dirs,
   any file a role writes "to the team").
3. **Task briefs** `tasks/<unit>.md`, which the gates read from `$repo/tasks/`.

So two runs in one clone overwrite each other's ledger, write artifacts into one
shared `.team/`, and fight over identically-named `tasks/u1.md` (the default unit
naming is generic `u1, u2, ...`, so collisions are the norm, not the exception).

## How it was observed

Two orchestrator sessions ran in the same clone
(`/home/fares/projects/claude-orchestrator`) at the same time:

| Run | TEAM_RUN_ID | TEAM_DIR | tmux | goal | working tree |
|---|---|---|---|---|---|
| A (this one) | `r177974008611364` | `.team-r177974008611364` | `orch-60650` | crosspaste-arrival-feedback | `~/projects/crosspaste` |
| B | `r177974012512194` | `.team-b9-e2e` | `orch-98934` | chart-no-data | `~/projects/souq` |

Symptoms seen in run A:

- `.team/state.md` written by run A was, seconds later, overwritten with run B's
  content (`# Team state: chart-no-data`), then reverted to the bare
  `templates/state.md` skeleton at other points.
- The `Edit`/`Write` tools repeatedly failed with "File has been modified since
  read" on `.team/state.md`, because run B was rewriting it between read and
  write.
- Both runs would have written `tasks/u1.md … u4.md`; run B's briefs would
  silently replace run A's, feeding the wrong `verify:`/`scope:`/`off-limits:`
  lines into run A's gates.

Note the wrinkle in run B's env: `TEAM_RUN_ID=r177974012512194` but
`TEAM_DIR=.team-b9-e2e`, i.e. run B's `TEAM_DIR` was set by an explicit override
rather than the `team-env.sh` derivation (`.team-$TEAM_RUN_ID` would give
`.team-r177974012512194`). The override path exists and is honored. This does not
change the bug: even with both runs' `TEAM_DIR` perfectly isolated, the ledger,
briefs, and artifacts are not under `TEAM_DIR`, so they still collide.

## Root cause (exact sites)

Per-run isolation is plumbed (`team-env.sh` derives `TEAM_DIR`; `team-spawn.sh`
exports `TEAM_RUN_ID` to children), but the following hardcode the shared paths
instead of `$TEAM_DIR`:

1. **Ledger location, orchestrator instructions.**
   - `roles/orchestrator.md:51` — "copy `templates/state.md` to `.team/state.md`".
   - `roles/orchestrator.md:84` — "`.team/state.md` is the source of truth".
   - `roles/orchestrator.md:189` — "Keep `.team/state.md`'s `## roster` section".
   - `bin/start-orchestrator.sh:56` — same "copy … to `.team/state.md`" wording.
   - `CLAUDE.md:33` — "Team state lives in `.team/state.md`".
   These all name the literal `.team/`, never `$TEAM_DIR`. The orchestrator
   session itself follows them and writes the ledger to the shared file.

2. **Role-facing artifact path, spawned-role prompt.**
   - `bin/lib/team-spawn.sh:125-127` — the generated role prompt says:
     > The team's scripts, templates, task briefs, and .team/ artifacts live at
     > `$ORCH_HOME` ($repo) … write team artifacts under `$ORCH_HOME/.team/`.
   So every role writes specs/evidence/etc. under the shared `$ORCH_HOME/.team/`,
   even though `$TEAM_DIR` is correctly set in its environment (`team-spawn.sh`
   exports `TEAM_RUN_ID` at line 144-145, so `team-env.sh` would resolve the
   per-run dir if the prompt pointed at `$TEAM_DIR`).

3. **Task briefs, read by the gates from the shared `tasks/`.**
   - `bin/verify-unit.sh:18` — `brief="$repo/tasks/$unit.md"`.
   - `bin/check-scope.sh:35` — `brief="$repo/tasks/$unit.md"`.
   Briefs live in `$repo/tasks/`, not `$TEAM_DIR`. Combined with generic unit
   names (`u1, u2, …`), two runs overwrite each other's briefs and the gates read
   whichever run wrote last.

For contrast, the parts that ARE correctly isolated and should be the model for
the fix: `check-scope.sh:42` (`basefile="$TEAM_DIR/base/$unit"`),
`verify-unit.sh` log dir (`$TEAM_DIR/verify`), `unit-start.sh`
(`$TEAM_DIR/base`), and all of `team-spawn.sh`'s `active`/roster handling.

## Reproduction

1. In one clone, start run A: `TEAM_RUN_ID=A` (or via `bin/run.sh`), give it a
   goal, let the orchestrator write `.team/state.md` and `tasks/u1.md`.
2. In a second terminal, in the same clone, start run B with a different
   `TEAM_RUN_ID` and a different goal.
3. Observe: `.team/state.md` flips to run B's goal; `tasks/u1.md` is whichever
   run wrote last; both runs' `verify-unit.sh u1` read the same brief.

`bin/run.sh` allocates a fresh `TEAM_RUN_ID` per invocation, so two `run.sh`
invocations in one clone is the normal way to hit this, exactly the parallel-team
use case the feature claims to support.

## Impact

- Ledger corruption: an orchestrator's source of truth is silently replaced by
  another run's, so status, unit list, and decision-log are unreliable.
- Brief corruption: gates (`verify-unit`, `check-scope`) can run against another
  run's `verify:`/`scope:`/`off-limits:` lines, producing false passes/failures.
- Artifact collisions in shared `.team/` (specs, evidence) when names coincide.
- Tool-level churn: "File modified since read" failures on `.team/state.md` for
  the orchestrator that loses the race.

## Proposed fix

Make the ledger, briefs, and role artifacts per-run, mirroring the infra dirs.
Keep legacy (no `TEAM_RUN_ID`) behavior so single-team clones are unchanged
(`team-env.sh` already falls back to `.team` and would fall back to `tasks/`).

1. **Ledger → `$TEAM_DIR/state.md`.**
   - `roles/orchestrator.md` (lines 51, 84, 189), `bin/start-orchestrator.sh:56`,
     and `CLAUDE.md:33` should reference `$TEAM_DIR/state.md` (with a note that
     `$TEAM_DIR` is `.team/` in legacy mode), not the literal `.team/state.md`.

2. **Role prompt → `$TEAM_DIR`.**
   - `bin/lib/team-spawn.sh:125-127`: change "write team artifacts under
     `$ORCH_HOME/.team/`" to "`$TEAM_DIR`" (already exported via `team-env.sh`
     once `TEAM_RUN_ID` is inherited, which it is). Verify `$TEAM_DIR` is in the
     spawned role's env (export it explicitly in the `launch=` block alongside
     `TEAM_RUN_ID`, or have the role source `team-env.sh`).

3. **Task briefs → per-run.** Two options:
   - (a) Move briefs under `$TEAM_DIR/tasks/<unit>.md` and update
     `verify-unit.sh:18` + `check-scope.sh:35` to read `$TEAM_DIR/tasks/$unit.md`
     (fall back to `$repo/tasks/$unit.md` in legacy mode), and update
     `roles/orchestrator.md` / `tasks/_TEMPLATE.md` guidance accordingly. Cleanest.
   - (b) Namespace unit ids per run (prefix with the run id or goal slug) so
     `tasks/<prefix>-<unit>.md` cannot collide. Less invasive to the gates but
     pushes naming discipline onto the orchestrator and still shares `tasks/`.
   Prefer (a): it makes isolation structural rather than convention-dependent.

4. **Audit for other shared-path hardcodes.** Grep the tree for literal `.team/`
   and `$repo/tasks` / `tasks/<unit>` and confirm each is either infra-correct
   (`$TEAM_DIR`) or intentionally shared.

5. **Cross-run safety check (optional, defense in depth).** On orchestrator
   start, if `TEAM_RUN_ID` is set and a `.team/state.md` (legacy path) exists for
   a *different* run, warn rather than overwrite.

## Acceptance criteria for the fix

- Two `bin/run.sh` invocations in one clone, different goals, run to completion
  without either run's `state.md`, briefs, or artifacts being touched by the
  other (verify by diffing each run's `$TEAM_DIR` and confirming no writes to a
  shared `.team/state.md`).
- Legacy single-team mode (no `TEAM_RUN_ID`) keeps writing to `.team/` and
  `tasks/` exactly as today (no behavior change, no broken paths).
- `verify-unit.sh` / `check-scope.sh` read the brief from the per-run location
  when `TEAM_RUN_ID` is set, and from `$repo/tasks/` otherwise.

## Affected files

- `bin/lib/team-spawn.sh` (role-prompt artifact path; ensure `$TEAM_DIR` exported)
- `bin/verify-unit.sh`, `bin/check-scope.sh` (brief lookup path)
- `roles/orchestrator.md`, `bin/start-orchestrator.sh`, `CLAUDE.md` (ledger path
  wording)
- `tasks/_TEMPLATE.md` (handoff path guidance), `templates/state.md` (header note)
- `bin/team-env.sh` (reference for the legacy/per-run fork; no change required if
  the consumers branch correctly)

## Workaround used in the affected session (run A)

Run A's orchestrator moved its own ledger to `$TEAM_DIR/state.md`
(`.team-r177974008611364/state.md`), namespaced its briefs `tasks/cpaf-u*.md`,
and copied the role-written spec to a protected per-run path
(`.team-r177974008611364/arrival-feedback-spec.md`). Roles coordinated over `/is`
and ran gates against `$TEAM_DIR`, so they did not depend on the clobbered
`.team/state.md`. This is a manual mitigation, not a fix; the defaults still
collide.

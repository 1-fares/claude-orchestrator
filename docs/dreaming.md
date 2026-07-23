# Dreaming: nightly memory consolidation

`bin/dreamer.sh` (LLM) + `bin/night-janitor.sh` (deterministic) keep a
long-running team's file-based memory small and true. They run when the team
is quiet, typically from cron.

## Why

The run's knowledge ledgers grow append-only and keep superseded entries:

- `state.md` accretes derive/challenge/re-derive chains; a ledger that only
  grows makes every compaction rehydration slower (roles/orchestrator.md
  already asks the orchestrator to prune at ~400 lines, manually).
- The operator decisions file keeps every intermediate verdict of closed
  sagas, including corrected false positives; the terminal state is
  inseparable from the debate history.
- `observer/history.md` appends a near-identical snapshot every cycle
  (observed live: 2.8 MB / 2,055 entries / ~227 KB per day).
- Stale notes are not just cost: they have caused real misbehavior
  (phantom-stall alarms from stale journal lines, day-old external-state
  claims re-raised for days; see the comments in bin/observer.sh).

Prior art, briefly: Letta's sleep-time agents / "Dreaming" over a markdown
memory directory, the reflection mechanism in Generative Agents (Park et al.
2023), Mem0's ADD/UPDATE/DELETE/NOOP resolution, Zep's supersede-with-
timestamps. The design principles adopted here: never destroy raw evidence;
supersede, do not erase; provenance on distilled claims; protect open/fresh
content mechanically; reviewable diff per cycle; idempotent; quiet-point only.

## The dreamer (bin/dreamer.sh)

One pass per artifact, each with the same shape: build a prompt, get an EDIT
SCRIPT from the model, apply it mechanically, archive first, swap atomically.

| artifact | transformation | archive |
|---|---|---|
| `observer/history.md` | whole days older than the fresh window digest into `observer/history-digest.md` (one section per day); fresh tail kept | raw entries gzipped under `dreams/archive/<stamp>/` |
| `state.md` | settled chains collapse to their terminal finding + provenance line; dead sections move out | `state-archive.md` (greppable) + `dreams/archive/` |
| `DECISIONS*.md` | resolved sagas collapse to final state + decision + date | `<name>-archive.md` + `dreams/archive/` |
| `reports/*.md` | index refresh only (`reports/INDEX.md`); report bodies are evidence and are never rewritten | previous INDEX kept |
| memory bank (`DREAMER_MEMORY_DIR`) | strategic facts promoted (update-not-duplicate, supersede-not-delete, frontmatter provenance); engine-lesson diffs STAGED under `dreams/proposed/`, never applied | prior entry versions under `dreams/archive/` |

Safety, enforced mechanically (not by prompt):

- **Edit script, not rewrite.** The model names exact section headers to
  COLLAPSE or ARCHIVE; anything unmentioned is kept verbatim byte-for-byte.
  A hallucinated header is a rejected op. (bin/lib/dream-lib.sh)
- **Fresh/undated protection.** No op may touch a section younger than
  `DREAMER_FRESH_HOURS` (default 48) or without a derivable date. Dreaming
  compresses the settled past, never the live present.
- **Archive before swap.** Removed sections are appended verbatim to the
  greppable archive files and the dated `dreams/archive/<stamp>/` dir before
  any live file changes; swaps are atomic (`mv`) with a lost-update guard
  (refuse if the source changed since it was read).
- **Quiescence gate.** Refuses to run unless every roster role classifies
  `idle` (bin/role-activity.sh), checked twice with a settle gap, under a
  flock. `--force` overrides for a supervised run.
- **Report per cycle.** `dreams/report-<stamp>.md`: op log, rejected ops,
  byte deltas, diffs. Reverting a cycle = restoring from the archive. A
  `_last dream: ..._` marker near the top of `state.md` points the
  orchestrator at the report on its next ledger read.
- **Budget.** `DREAMER_MAX_CALLS` caps model calls per run; a convergence
  floor (`DREAMER_MIN_ELIGIBLE_LINES`) skips the model entirely when an
  artifact has nothing old enough to consolidate.

Modes: `--report-only` (aka `--dry-run`) runs the full pipeline including
model calls but stages everything under `dreams/staged/` and changes no live
file; use it for the first nights on a new deployment and compare. Default
mode applies. `--artifact <name>` limits to one artifact.

## The janitor (bin/night-janitor.sh)

Deterministic retention for bulk that carries no unique information: ledger
`.bak-*` thinning (keep newest N, gzip the rest), ticket-attachment expiry
(they remain re-downloadable from the tracker), dream-archive expiry
(default 90 days, the ONLY place dreamed raw evidence ever expires), and
opt-in inter-session-bus retention (`NJ_BUS_DIR`). Dry-run by default;
`--apply` executes. No LLM.

## Scheduling

Both discover the newest `.team-r*` run when `TEAM_RUN_ID` is unset, so a
static crontab entry survives run-id changes:

```cron
# nightly, during the quiet window; janitor first, then the dreamer
15 2 * * * cd <clone> && bin/night-janitor.sh --apply >> .team-backup.log 2>&1
30 2 * * * cd <clone> && DREAMER_MODEL=opus bin/dreamer.sh >> .team-backup.log 2>&1
```

The quiescence gate, not the clock, is the real protection: an unusual
late-night mission makes the dreamer refuse and try again the next night.

Model choice: this job rewrites the team's memory once per day on a few
hundred KB of input; the cost of the best available model is small and the
cost of a bad rewrite is high. Configure `DREAMER_MODEL` (and
`DREAMER_EFFORT`, passed to `claude --effort`) accordingly; the janitor
costs nothing.

## Relation to B13

BACKLOG.md B13 (continuous learning loop) describes lesson capture from the
run's exhaust with consequence-routed application. The dreamer implements the
consolidation/apply half offline: untracked private state it rewrites itself
under the safety rules above; anything that would change tracked files
(roles/, CLAUDE.md, bin/) only ever lands as a staged proposal under
`dreams/proposed/` for operator review, which is B13's own hazard rule
(propose-and-review, never self-applied).

## Tests

`bin/tests/dreamer-editscript-test.sh` (parser/applier invariants: verbatim
keep, fresh protection, hallucinated-header rejection, archive completeness,
swap guard), `bin/tests/dreamer-run-test.sh` (end-to-end with a fake model:
digestion, idempotent rerun, report-only staging, quiescence, convergence
floor), `bin/tests/night-janitor-test.sh` (retention rules, dry-run default).

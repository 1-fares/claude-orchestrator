# Model policy and token economy

How the team assigns a model to each role, and the disciplines that keep a
top-tier team affordable without losing effectiveness. The actuation point is
`model_for()` in [`bin/lib/team-spawn.sh`](../bin/lib/team-spawn.sh); this doc
is the rationale and the tuning guide.

## The cost model

Three facts drive everything here:

1. **Price per token spans 80x across tiers.** Vendor list prices read on
   2026-11-10, per million tokens, input/output: Fable 5.2 $8/$40, Opus 5.5
   $4/$20, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50 (prompts up to 100k
   tokens). Fable's base price is 2x Opus; a cache read costs the same on both
   ($0.20). On a subscription the same ratios apply as quota weight rather
   than dollars.
2. **An idle role costs almost nothing.** A persistent session parked on the
   bus makes no API call until a message, or the bus-inbox heartbeat (every 2 h
   with the documented `wait <name> 7200`), wakes it for one short turn. Team
   size is almost free; team *activity* is what costs.
3. **The expensive state is a large context.** Every turn re-reads the whole
   window (cached, but cached reads still bill and still weigh on quota). A
   session that drifted to a near-full window pays for that drift on every
   subsequent turn until it compacts. On fable the new input and output of
   each such turn cost double; the cached re-read costs the same as on opus.

So the policy optimizes two products: (model price) x (tokens per turn) x
(turns). The first factor is the tier table; the second is context discipline;
the third is the run design (batching, briefs, gates) that already exists.

## The tier table

`model_for()` matches the full role name (digit suffixes included):

| Tier | Default | Roles | Why |
|---|---|---|---|
| top | `fable` | `orchestrator`, `communicator*`, `user-communicator*`, `reviewer*`, `peer-reviewer*`, `tester*`, `fact-checker*`, `architect*`, `analyst*` | Judgment quality bounds the whole run: a wrong decomposition, a missed bug, a bad acceptance call costs more rework tokens downstream than the tier premium costs upfront. |
| mid | `opus` | `implementer*`, `backend*`, `frontend*`, `writer*`, `editor*`, `researcher*`, `integrator`, legal roles, designers, and any unmatched role | Produces the work product. Strong enough to one-shot most units; errors are caught by the top-tier verification roles. |
| cheap | `sonnet` | `devops*`, `copy-editor*`, `paralegal*`, `doc-integrator*` | Rule-following, mechanical work with no quality loss on a smaller model. |
| relay | `haiku` | `relay*`, `poller*` | Read-only display or message relay. |

The asymmetry is deliberate: generation (mid tier) is cheaper to redo than a
bad judgment is to unwind. Adversarial verification on the top tier catches
mid-tier mistakes; that is the cheapest place to spend the premium.

## Overrides

Highest precedence first; values are `claude --model` aliases or full ids:

```
TEAM_MODEL_<ROLE>     per-role, role name upcased with '-' -> '_'
                      (TEAM_MODEL_REVIEWER2=opus)
TEAM_MODEL_TOP        the top tier's model        (default fable)
TEAM_MODEL_DEFAULT    the mid tier / fallback     (default opus)
```

An operator without top-tier access runs `TEAM_MODEL_TOP=opus` and gets the
pre-fable behavior. A cost-capped run can do `TEAM_MODEL_TOP=opus
TEAM_MODEL_DEFAULT=sonnet`.

The launch records each role's model under `$TEAM_DIR/models/<role>`. The
observer reads those records (ground truth, no process parsing) and the
compaction watchdog keys each role's thresholds off that role's record.

## Headless calls pin their model

Every `claude -p` call the machinery makes is pinned to an explicit model,
never the operator's interactive default:

- `bin/gates/llm-judge.sh` (and its wrappers `rubric-judge`, `cite-support`)
  defaults to **sonnet** (`LLM_JUDGE_MODEL` or `--model` to override). K-vote
  majority judging multiplies the per-call cost by K; a small-rubric verdict
  does not need the top tier. Pass `--model opus` (or `fable`) only where the
  verdict quality itself bounds the run.
- `bin/observer.sh` defaults to **sonnet**, the cheap tier (`OBSERVER_MODEL`).
- `bin/dreamer.sh` defaults to **opus**, the middle tier (`DREAMER_MODEL`): it
  rewrites the ledger once a day, and a bad rewrite costs more than the calls
  (`docs/dreaming.md`).

## Context-size disciplines (the second factor)

These already exist in the role specs and the machinery; they matter more on
fable, whose base input and output price is 2x opus:

- **Bulk reads go to sub-agents.** A top-tier role that needs to read many
  files or sweep a codebase dispatches Task sub-agents and reads only the
  conclusions. The sub-agent's context is discarded; the expensive window
  grows by a summary, not by the corpus.
- **File pointers over inline content.** Bus messages longer than a sentence
  travel as `--file` pointers; specs and evidence live under `$TEAM_DIR`, not
  in anyone's window.
- **Earlier compaction on fable.** The compaction watchdog's per-role defaults
  drop from nudge 80% / force 90% to **70% / 85%** for every role whose
  `$TEAM_DIR/models/<role>` record starts with `fable`. The lower thresholds
  rest on fable's 2x base input and output price, not on cache reads, which
  cost the same as on opus. Explicit `COMPACT_NUDGE_PCT` /
  `COMPACT_FORCE_PCT` still win.
- **The ledger stays bounded** (roles/orchestrator.md): closed units move to
  `state-archive.md` so post-compaction rehydration stays cheap.
- **Pause over retire for an idle role** (idle is nearly free; context is valuable),
  but checkpoint+compact at task boundaries (a large window is not).

## Watching it live

The observer reports per-role models every cycle and flags the single most
expensive misallocation: a top-tier role doing mechanical work. Its MODELS
section names the role and the suggested tier; the orchestrator actuates by
retire+respawn (after changing `model_for()` or setting `TEAM_MODEL_<ROLE>`).

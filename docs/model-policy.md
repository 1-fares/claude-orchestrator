# Model policy and token economy

How the team assigns a model to each role, and the disciplines that keep a
top-tier team affordable without losing effectiveness. The actuation point is
`model_for()` in [`bin/lib/team-spawn.sh`](../bin/lib/team-spawn.sh); this doc
is the rationale and the tuning guide.

## The cost model

Three facts drive everything here:

1. **Cost per token spans ~10x across tiers** (haiku < sonnet < opus < fable;
   fable is ~2x opus per token). On a subscription the same ratios apply as
   quota weight rather than dollars.
2. **An idle role costs nothing.** A persistent session parked on the bus makes
   no API call until a message wakes it. Team size is almost free; team
   *activity* is what costs.
3. **The expensive state is a large context.** Every turn re-reads the whole
   window (cached, but cached reads still bill and still weigh on quota). A
   session that drifted to a near-full window pays for that drift on every
   subsequent turn until it compacts. On fable the same drift costs double.

So the policy optimizes two products: (model price) x (tokens per turn) x
(turns). The first factor is the tier table; the second is context discipline;
the third is the run design (batching, briefs, gates) that already exists.

## The tier table

`model_for()` matches the full role name (digit suffixes included):

| Tier | Default | Roles | Why |
|---|---|---|---|
| top | `fable` | `orchestrator`, `communicator`, `reviewer*`, `peer-reviewer*`, `tester*`, `fact-checker*`, `architect*`, `analyst*` | Judgment quality bounds the whole run: a wrong decomposition, a missed bug, a bad acceptance call costs more rework tokens downstream than the tier premium costs upfront. |
| mid | `opus` | `implementer*`, `backend*`, `frontend*`, `writer*`, `editor*`, `researcher*`, `integrator`, legal roles, designers, and any unmatched role | Produces the work product. Strong enough to one-shot most units; errors are caught by the top-tier verification roles. |
| cheap | `sonnet` | `devops*`, `copy-editor*`, `paralegal*`, `doc-integrator*` | Rule-following, mechanical work with no quality loss on a smaller model. |
| relay | `haiku` | `dashboard*`, `relay*`, `poller*` | Read-only display or message relay. |

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
compaction watchdog keys its thresholds off the orchestrator's record.

## Headless calls stay cheap

Every `claude -p` call the machinery makes is pinned to an explicit cheap
model, never the operator's interactive default:

- `bin/gates/llm-judge.sh` (and its wrappers `rubric-judge`, `cite-support`)
  defaults to **sonnet** (`LLM_JUDGE_MODEL` or `--model` to override). K-vote
  majority judging multiplies the per-call cost by K; a small-rubric verdict
  does not need the top tier. Pass `--model opus` (or `fable`) only where the
  verdict quality itself bounds the run.
- `bin/observer.sh` defaults to **sonnet** (`OBSERVER_MODEL`).

## Context-size disciplines (the second factor)

These already exist in the role specs and the machinery; they matter twice as
much on fable:

- **Bulk reads go to sub-agents.** A top-tier role that needs to read many
  files or sweep a codebase dispatches Task sub-agents and reads only the
  conclusions. The sub-agent's context is discarded; the expensive window
  grows by a summary, not by the corpus.
- **File pointers over inline content.** Bus messages longer than a sentence
  travel as `--file` pointers; specs and evidence live under `$TEAM_DIR`, not
  in anyone's window.
- **Earlier compaction on fable.** The compaction watchdog's defaults drop
  from nudge 80% / force 90% to **70% / 85%** when `$TEAM_DIR/models/
  orchestrator` records fable, because every turn taken in a large window
  costs double there. Explicit `COMPACT_NUDGE_PCT` / `COMPACT_FORCE_PCT` still
  win.
- **The ledger stays bounded** (roles/orchestrator.md): closed units move to
  `state-archive.md` so post-compaction rehydration stays cheap.
- **Pause over retire for an idle role** (idle is free; context is valuable),
  but checkpoint+compact at task boundaries (a large window is not).

## Watching it live

The observer reports per-role models every cycle and flags the single most
expensive misallocation: a top-tier role doing mechanical work. Its MODELS
section names the role and the suggested tier; the orchestrator actuates by
retire+respawn (after changing `model_for()` or setting `TEAM_MODEL_<ROLE>`).

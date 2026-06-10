# Operator-authority model

How much of the run stops on a human, and how to shrink that safely. This doc
describes the third stage of an operator-gating maturity ladder. The engine
default is stage two; stage three is an explicit, revocable operator grant,
never self-assumed by the team (see the pointer block in
`roles/orchestrator.md`).

## The maturity ladder

1. **Gate everything.** Every consequential step waits for an operator reply.
   Safe and slow; the operator is the bottleneck on every path.
2. **Gate production (the engine default).** Pushing work branches and opening
   PRs is routine; merging to a protected/production branch, production
   deploys, and destructive operations wait for an explicit GO.
3. **Gate only real decisions.** Go-confirmations execute under a mandatory
   safety protocol; only genuine judgment calls stop on the operator.

The move from 2 to 3 is justified when measurement shows the operator gate
dominating lead time AND the gated actions are mostly go-shaped: the homework
is done, the evidence is verified, there is one sensible option, and the
operator's answer would predictably be "approve". Asking a human to confirm a
foregone conclusion buys no safety and costs the wait.

## Real decision vs go-confirmation

A REAL DECISION stops on the operator, with the homework attached:

- multiple defensible options with material tradeoffs (product, architecture,
  security, money, legal);
- accepting a security gap or weakening auth/isolation;
- anything whose reversal is not scripted and verified in advance;
- external communications to new audiences, or commitments made on the
  operator's behalf;
- lifting any standing hold the operator has explicitly placed.

A GO-CONFIRMATION is automated only when ALL of these hold:

- the homework is done and ledgered;
- the evidence is verified (per `docs/verification-disciplines.md`);
- there is one sensible option;
- the team's recommendation would be "approve";
- a pre-staged, PROVEN rollback exists.

If any leg is missing, it is not a go-confirmation. When unsure, treat it as a
real decision.

## The safety protocol (mandatory, every formerly-gated action)

1. **Homework ledgered BEFORE execution:** the exact change list, the risk,
   the user-perceptible impact, the evidence, and the rollback commands.
2. **Pre-staged proven rollback:** backup tables, the previous deploy ref plus
   a tested revert path, config snapshots. "Proven" means exercised, not
   described.
3. **Object window** for production-touching actions: push the one-line intent
   plus a homework pointer to the operator's notification channel (e.g. ntfy),
   then wait a bounded interval (15 minutes is a workable default). Silence =
   proceed; any operator reply stops the action.
4. **Post-action verify** against rollback triggers written down BEFORE the
   action. If a trigger fires, roll back without asking, then notify the
   outcome.
5. **Staged trust:** the first automated production deploy and the first
   automated production data write each get a second role independently
   re-checking the homework before the object window opens, plus a full report
   afterward. Trust is extended one action class at a time, not granted
   wholesale.

Every object-window notification and automated execution gets a ledger entry
and appears in the periodic operator summary. Nothing in this protocol is
silent.

## The revert lever

Any operator stop, hold, or revert message, on any channel, restores the
previous full-gating regime immediately and entirely, mid-action where
possible. The lever is what makes the grant safe to give: the operator can
always buy back the old behaviour with one message, without negotiation.

## What does not change

Stage three does not relax verification, scope discipline, or the ledger. It
changes WHO confirms a go, not what must be true before one. The read-only
default posture toward production, the care standard, and every discipline in
`docs/verification-disciplines.md` stand unchanged.

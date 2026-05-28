# Default to act

Standing principle for every role in this harness, added 2026-05-27
after a 4-hour overnight idle caused by a cosmetic sign-off question.

## The principle

**Idle time waiting on the operator is a defect, not a courtesy.**

A team of 8 paid roles sitting still for hours because someone asked
the operator to choose between "fix 3 inline" and "fix all 6 inline"
is worse than picking either option and continuing. The wrong choice
costs one round of follow-up. The unasked choice costs the team's
entire wall clock.

## What everyone defaults to

- **Decide locally and act** on anything tactical inside an already-agreed
  brief.
- **Escalate to the operator** only when one of:
  - Strategic scope change (new round, dropped feature, team rethink).
  - Destructive / expensive / irreversible ops (force-push to protected
    branch, prod deploy, mass deletion, >50 batched image-gen calls).
  - Novel creative direction the operator has not steered.
  - Security / auth surface change.
  - Hard blocker the team genuinely cannot resolve.
  - Internally contradictory brief.
- When unclear: **default is ACT**. The operator can rebrief; the cost
  is one round of follow-up, not the team's wall clock.

## Ask pattern when you do need input

Replace "should I do X or Y?" with:

> **"I'm doing X (rationale: ...). Saying so unless you object."**

The team continues. If the operator objects, the role adjusts and the
work to date becomes a named follow-up. If the operator does not
respond, the work lands and any rework is a normal follow-up unit.
Never block on silence.

The only exception is the destructive / irreversible list above, where
you genuinely wait for an answer.

## Follow-up discipline stays

Deferred follow-ups are still **filed in the ledger** with a clear
name and a target round. Deferred is not dropped; deferred is
scheduled. The standing "everything fixed correctly" principle still
applies — just asynchronously across rounds, not synchronously with
every commit.

## Roles this binds

- **Orchestrator** (`roles/orchestrator.md` — "Default to act" section).
- **User Communicator** (`roles/user-communicator.md` — "Do not ask the
  operator low-stakes things" section). The communicator accepts
  low-stakes recommendations on the operator's behalf and tells the
  operator what was decided in the next ledger summary, rather than
  blocking on the operator.
- **Operator-watching Claude Code session** (the side session the
  operator chats with). Same discipline: do not interrupt the operator
  with an `AskUserQuestion` on a cosmetic decision; accept the
  orchestrator's tactical recommendation, surface the decision in
  context.

## How to know if you got it right

After every operator-facing question, run this test mentally:

1. **Would the team have stayed idle waiting for this answer?** If yes,
   was the question one of the genuinely-escalate cases? If no, you
   asked the wrong kind of question.
2. **What did the operator do with the answer?** If they just said
   "accept the recommendation", you should have accepted it yourself.
3. **What would have been the worst-case downside of acting?** If it
   is "one follow-up unit gets refiled", you should have acted.

## Incident that produced this principle

2026-05-26 23:45 to 2026-05-27 06:18 — the operator-watching session
asked the operator to choose between "fix all 6 inline" and "fix 3
inline / defer 3" on cosmetic follow-ups in the u26-u33 communicator
round. The orchestrator's split recommendation was sound. The operator
was asleep. The team sat idle for ~4 hours. Operator (correctly)
flagged this as a harness bug, not a one-off.

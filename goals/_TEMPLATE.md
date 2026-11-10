# Goal: <short title>

Copy this file to `goals/<name>.md`, fill it in, then start the orchestrator
with it (it proposes the team and launches the roles after your `go`):

    bin/start-orchestrator.sh goals/<name>.md   # then: bin/attach.sh

`bin/new-goal.sh` writes a brief with the same headings from a few answers;
the orchestrator fills any heading left empty at its READY gate. This file is
the per-run goal input; run state lives in the ledger (`$TEAM_DIR/state.md`).
The role prompts and CLAUDE.md do not change between runs; only this brief does.

## Working tree

<Where the code lives, e.g. `~/projects/app-a`; this may differ from this
orchestrator repo. `(this clone)` means greenfield here.>

## What I want

<One or two paragraphs. What is the goal, in plain terms? Why does it matter?
What does success look like from the user's point of view? Name the relevant
existing code (files, modules, services) and the constraints (runtime, platform,
performance, compatibility, deadlines).>

## Acceptance criteria

<Concrete, checkable conditions. Each should be something the tester can verify.
The analyst refines these if a session is assigned that role.>

- <criterion 1>
- <criterion 2>

## Scope

In scope: <what this run should change>
Out of scope: <what it must not change; keeps the team from gold-plating and
the orchestrator able to hold the line>

## Team

<The orchestrator decides finally, but suggest a starting composition, e.g.
analyst, architect, implementer1, tester1, reviewer1, devops, deployment. The
orchestrator itself is always present.>

## Notes

<Anything the team should know up front: prior attempts, risky areas, decisions
already made, open questions to resolve early, the verify command if known.>

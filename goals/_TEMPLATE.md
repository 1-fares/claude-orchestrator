# Goal: <short title>

Copy this file to `goals/<name>.md`, fill it in, then launch:

    bin/launch-team.sh goals/<name>.md <role> [<role> ...]

This file is the entire per-run state. The role prompts and CLAUDE.md do not
change between runs; only this brief does.

## What we are building

<One or two paragraphs. What is the goal, in plain terms? Why does it matter?
What does success look like from the user's point of view?>

## Context

- **Repository / working tree:** <where the code lives; this may differ from
  this orchestrator repo>
- **Relevant existing code:** <files, modules, services the change touches>
- **Constraints:** <runtime, platform, performance, compatibility, deadlines>

## Acceptance criteria

<Concrete, checkable conditions. Each should be something the tester can verify.
The analyst refines these if a session is assigned that role.>

- [ ] <criterion 1>
- [ ] <criterion 2>

## Scope

**In scope:** <what this run should change>

**Out of scope / non-goals:** <what it must not change; keeps the team from
gold-plating and the orchestrator able to hold the line>

## Suggested team

<The orchestrator decides finally, but suggest a starting composition.>

- orchestrator (you, always)
- <e.g. analyst, architect, implementer1, tester1, reviewer1, devops, deployment>

## Notes / known unknowns

<Anything the team should know up front: prior attempts, risky areas, decisions
already made, open questions to resolve early.>

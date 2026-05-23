# Task: <unit-id>

The structured handoff from orchestrator to a role. Copy to
`tasks/<unit-id>.md`, fill in, then assign with a file pointer
(`/is s <role> --file tasks/<unit-id>.md`). The machine-readable header lines
(keys ending in `:`) are read by `bin/verify-unit.sh` and `bin/check-scope.sh`,
keep them and put one value per line.

<!-- machine-readable header -->
unit: <unit-id>
verify: <command that builds, tests, and lints this unit; must exit 0>
scope: <paths this unit may change, comma- or space-separated>
off-limits: <paths this unit must not touch, or ->
depends-on: <unit ids this waits on, or ->

## Inputs

<links, files, the design or contract this unit implements>

## Acceptance criteria

Verifiable assertions. Each should be something `verify:` or a test can check.

- [ ] <criterion>
- [ ] <criterion>

## In scope / out of scope

In: <what this unit changes>
Out: <what it must not change; gold-plating to avoid>

## Notes

<prior attempts, risky areas, decisions already made, open questions>

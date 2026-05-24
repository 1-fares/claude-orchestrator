# Goal: bugfix-validatorjs

## Working tree
~/projects/tests/bugfix-validatorjs
(already on branch `orch/bugfix`, checked out at the buggy state)

## What I want
Fix a real bug in this third-party library (the `validator.js` package).

The bug: `isDate()` throws a TypeError on certain invalid inputs instead of
returning `false`, when the date string and the format have a different number
of parts.

Reproduction (confirmed): `isDate('2018-01', 'YYYY-MM-DD')` throws instead of
returning `false`.

Do this:
1. Run the existing test suite to confirm a green baseline.
2. Add a failing regression test that reproduces the bug (capture the red run).
3. Find the root cause and fix it minimally so the function returns `false`
   (never throws) on such inputs.
4. Re-run the full suite; it must be green (capture it).
5. Write a one-paragraph note (bug, root cause, fix) in the working tree.

## Acceptance criteria
- A captured red log (the new test failing before the fix).
- A minimal fix in `src/lib/isDate.js`.
- A captured green log: the full suite passes.
- All work on branch `orch/bugfix`; do not commit to the default branch.
- No unrelated changes (no touching other validators).

## Scope
In scope: `src/lib/isDate.js` and the date test file(s), plus a short writeup.
Out of scope: other validators, build config, dependency changes, reformatting.

## Team
Lean: implementer, tester, reviewer. The orchestrator sizes the team.

## Notes
- Node project: `npm install`, then the project's test command (`npm test`).
  The suite is large; ensure the FULL suite stays green, not just the new test.
  A focused run while iterating is fine, but the final gate is the full suite.
- Verify command: the repo's `npm test` (exits 0).
- Record the unit baseline with `$ORCH_HOME/bin/unit-start.sh <unit>` in this
  tree before work.

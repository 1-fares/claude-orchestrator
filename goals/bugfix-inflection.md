# Goal: bugfix-inflection

## Working tree
~/projects/tests/bugfix-inflection
(already on branch `orch/bugfix`, checked out at the buggy state)

## What I want
Fix a real bug in this third-party library (the `inflection` Python package).

The bug: `titleize()` only capitalizes words that begin with a plain ASCII a-z
letter, so words starting with an accented/non-ASCII letter are left lowercase.

Reproduction (confirmed):
- `inflection.titleize("ana índia")` returns `"Ana índia"` but should return
  `"Ana Índia"` (the accented `í` must be capitalized).

Do this:
1. Run the existing test suite to confirm a green baseline.
2. Add a failing regression test that reproduces the bug (capture the red run).
3. Find the root cause and fix it minimally.
4. Re-run the full suite; it must be green (capture it). The new test passes and
   nothing else regresses.
5. Write a one-paragraph note (bug, root cause, fix) in the working tree.

## Acceptance criteria
- A captured red log (the new test failing before the fix).
- A minimal fix in `inflection.py`.
- A captured green log: the full suite passes.
- All work on branch `orch/bugfix`; do not commit to the default branch.
- No unrelated changes (no refactors, no reformatting, no other functions).

## Scope
In scope: `inflection.py` and `test_inflection.py`, plus a short writeup file.
Out of scope: other functions, dependency changes, reformatting, docs/changelog.

## Team
Lean: an implementer to fix, a tester to hold the red->green line, a reviewer for
root-cause + scope. The orchestrator sizes the team.

## Notes
- Pure Python, no runtime dependencies. Use uv: `uv venv` then
  `uv run pytest -q` (the suite is in `test_inflection.py`).
- Verify command: `uv run pytest -q` (exits 0).
- Record the unit baseline with `$ORCH_HOME/bin/unit-start.sh <unit>` in this
  tree before work, so check-scope attributes only this unit's changes.

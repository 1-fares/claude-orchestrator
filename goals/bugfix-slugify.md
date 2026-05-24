# Goal: bugfix-slugify

## Working tree
~/projects/tests/bugfix-slugify
(already on branch `orch/bugfix`, checked out at the buggy state)

## What I want
Fix a real bug in this third-party library (the `python-slugify` package).

The bug: when building the table of uppercase special-character translations,
only the FIRST special character's uppercase mapping is applied; the rest are
silently dropped. Symptom: uppercase accented / Cyrillic characters are not
transliterated consistently with their lowercase forms.

Do this:
1. Run the existing test suite to confirm a green baseline.
2. Add a failing regression test that reproduces the bug (capture the red run) —
   e.g. assert that the uppercase translations include more than just the first
   entry, or that `slugify` transliterates an uppercase special char correctly.
3. Find the root cause and fix it minimally.
4. Re-run the full suite; it must be green (capture it).
5. Write a one-paragraph note (bug, root cause, fix) in the working tree.

## Acceptance criteria
- A captured red log (the new test failing before the fix).
- A minimal fix under `slugify/`.
- A captured green log: the full suite passes.
- All work on branch `orch/bugfix`; do not commit to the default branch.
- No unrelated changes.

## Scope
In scope: `slugify/` and `test.py`, plus a short writeup file.
Out of scope: unrelated refactors, reformatting, version bumps, docs/changelog.

## Team
Lean: implementer, tester, reviewer. The orchestrator sizes the team.

## Notes
- Has a runtime dependency (`text-unidecode`). Use uv to set up and run, e.g.
  `uv venv && uv pip install -e . text-unidecode` or `uv run --with text-unidecode`.
  The suite is `test.py` (unittest); verify with `uv run python -m unittest` or
  `uv run python test.py`. Decide the exact command from the repo and record it.
- Record the unit baseline with `$ORCH_HOME/bin/unit-start.sh <unit>` in this
  tree before work.

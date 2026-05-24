# Goal: repo-bugfix

## Working tree
Per repo, under ~/projects/tests/ (one cloned copy each, e.g.
~/projects/tests/bugfix-<repo>). Not this orchestrator clone.

## What I want
Exercise the orchestrator on brownfield bug-fixing in real third-party code,
rather than greenfield construction. Clone 2-3 small, real GitHub repositories
(each with an existing automated test suite) into separate working trees, and for
each: reproduce a real bug with a failing test, fix it correctly and minimally,
and get the full suite green, with no unrelated changes.

Per-repo method:
1. Clone a copy. Run the existing suite to establish a green baseline (record the
   command and result).
2. Select one bug, by either: an open issue with a clear, runnable reproduction;
   or checking out the commit immediately before a known upstream bugfix (so the
   upstream fix is available as ground truth for "what correct looks like").
3. Add or restore a failing regression test that demonstrates the bug (red log
   captured).
4. Fix the code minimally. Rerun the suite (green log captured); the regression
   test now passes and nothing else regressed.
5. Reviewer confirms the fix addresses the root cause, not just the symptom, and
   that the diff is scoped to the bug.

## Acceptance criteria
- For each of 2-3 repos: a captured red log (failing regression test), a minimal
  fix, a captured green log (full suite passing), and a one-paragraph writeup
  (bug, root cause, fix) committed in that repo's working tree.
- All work is isolated on a branch (e.g. `orch/bugfix`); the repo's default branch
  is never committed to.
- No feature work, no unrelated refactors, no dependency bumps unrelated to the
  bug.

## Scope
In scope: cloning copies into ~/projects/tests/, and per repo the failing test +
fix + writeup on an isolated branch.
Out of scope: upstream pull requests, feature additions, broad refactors,
dependency upgrades unrelated to the bug, and anything touching the user's other
projects outside ~/projects/tests/.

## Team
architect/triage to select and reproduce the bug, implementer to fix, tester to
hold the red->green line, reviewer for root-cause + scope, integrator to land the
branch. The orchestrator may run repos sequentially or in parallel worktrees.

## Notes
- Candidate repos (operator confirms the final set before any clone; each must
  have a fast, hermetic test suite and a genuinely reproducible bug verified at
  clone time, not assumed): small single-purpose libraries are preferred over
  large frameworks. Pick a mix if useful (e.g. one Python lib run via uv, one JS
  lib run via npm). The exact repo + bug for each is confirmed with the operator
  after the baseline run and reproduction, before the fix begins.
- Internet access is used only to clone. Test suites must run offline/hermetic.
- Python repos run under uv; JS repos under npm. The verify command is per repo
  (the repo's own test runner), recorded in each unit's task brief.
- Honor each repo's own CLAUDE.md / contributing conventions if present; never
  push to any upstream remote.

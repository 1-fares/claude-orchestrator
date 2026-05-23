# Goal: slugify demo (first end-to-end test)

## What we are building
A tiny slugify function, the first real run of the orchestrator. Build it in an
EXTERNAL target repo (not this clone) to exercise --workdir mode.

## Working tree
~/orch-demo   (throwaway git repo; greenfield inside it)

## Acceptance criteria
- slugify.py exposes slugify(text: str) -> str: lowercase, trim, replace any run
  of non-alphanumeric characters with a single '-', strip leading/trailing '-'.
- test_slugify.py asserts: slugify("Hello, World!")=="hello-world",
  slugify("  A__B  ")=="a-b", slugify("")=="".
- `python3 test_slugify.py` exits 0.

## Scope
In: slugify.py, test_slugify.py (in the working-tree root).
Off-limits: everything else.

## Team and mode (keep minimal)
implementer1 and tester1 only. Serialize: no worktrees, no analyst/architect/
integrator. Interactive mode.

## Unit verify command
python3 test_slugify.py

## Launch command (use exactly this)
bin/launch-team.sh --workdir ~/orch-demo goals/slugify-demo.md implementer1 tester1

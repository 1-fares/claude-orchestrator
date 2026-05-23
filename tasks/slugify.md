# Task: slugify

The structured handoff for the slugify implementation.

<!-- machine-readable header -->
unit: slugify
verify: python3 test_slugify.py
scope: slugify.py
off-limits: test_slugify.py
depends-on: -

## Inputs

Goal brief: ~/projects/claude-orchestrator/goals/slugify-demo.md
Working tree: ~/orch-demo (your cwd; write the file there).

## Acceptance criteria

- [ ] slugify.py defines `slugify(text: str) -> str`.
- [ ] Lowercases the input.
- [ ] Trims leading/trailing whitespace.
- [ ] Replaces any run of non-alphanumeric characters with a single '-'.
- [ ] Strips leading and trailing '-' from the result.
- [ ] slugify("Hello, World!") == "hello-world"
- [ ] slugify("  A__B  ") == "a-b"
- [ ] slugify("") == ""

## In scope / out of scope

In: slugify.py in the working-tree root.
Out: test_slugify.py (tester1 owns it), anything else in the tree. No CLI,
no extra options, no transliteration, no dependencies. Pure stdlib.

## Notes

The unit verify (`python3 test_slugify.py`) needs test_slugify.py, which
tester1 writes next. You can self-check with a quick inline assert, but the
gate runs once the test file exists. Report `done:` when slugify.py is written
and self-verified; I will sequence the tester after you.

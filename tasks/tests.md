# Task: tests

The structured handoff for the slugify test.

<!-- machine-readable header -->
unit: tests
verify: python3 test_slugify.py
scope: test_slugify.py
off-limits: slugify.py
depends-on: slugify

## Inputs

Goal brief: ~/projects/claude-orchestrator/goals/slugify-demo.md
Working tree: ~/orch-demo (your cwd; write the file there).
slugify.py already exists in the tree (implementer1's unit).

## Acceptance criteria

- [ ] test_slugify.py imports slugify from slugify.py.
- [ ] Asserts slugify("Hello, World!") == "hello-world".
- [ ] Asserts slugify("  A__B  ") == "a-b".
- [ ] Asserts slugify("") == "".
- [ ] `python3 test_slugify.py` exits 0.

## In scope / out of scope

In: test_slugify.py in the working-tree root.
Out: slugify.py (implementer1 owns it; do not edit it). If a test fails
because of a bug in slugify.py, do not patch slugify.py, report the failing
case back to me and I route it to implementer1.

## Notes

The three asserts come straight from the goal's acceptance criteria. Run
`python3 test_slugify.py` yourself; report `done:` only with a clean exit 0.

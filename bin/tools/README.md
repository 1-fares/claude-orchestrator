# bin/tools — shared toolbox

Small, generic, coding-oriented helpers that roles invoke instead of
re-deriving the same boilerplate each run. Same delivery model as `bin/gates`:
in-repo scripts a role calls as `$ORCH_HOME/bin/tools/<name>`, portable with the
clone, no global install. Awareness comes from the CLAUDE.md charter every role
reads at startup, not from a per-session skills mechanism (which would need a
global `~/.claude` install, outside this public repo, or would pollute the
target project's tree).

Each tool prints a short, machine-readable report and does one thing. They are
heuristics where noted; treat their output as a lead, not proof.

| Tool | Use it when | Serves |
| :-- | :-- | :-- |
| `probe-env.sh [DIR]` | Starting on an unfamiliar repo; filling a brief's `verify:` line | orchestrator, devops, implementer |
| `impact-scan.sh <file\|symbol>` | Scoping a change; gauging blast radius before editing | implementer, reviewer |
| `red-green.sh <red\|green> <unit> <cmd...>` | Capturing the tester's failing-then-passing evidence pair | tester |
| `diff-summary.sh [range]` | Grasping a change without reading the whole diff | reviewer, integrator |

Keep them dependency-light (POSIX bash; `jq`/`rg` used when present, degrade
without). Grow the set from the retro loop: when a task recurs by hand across
runs, that is the signal to add a tool here, not a speculative brainstorm.

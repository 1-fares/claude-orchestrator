# Review-ready PR packet

When a human review gate sits on the critical path, the wait is largely the
gate not being engineered to be CHEAP: a reviewer who has to reconstruct the
change, judge the risk, and hunt for evidence cannot give a one-word GO. In a
measured value stream the human-review wait dominated the lead time of
high-risk fixes. A review-ready packet front-loads exactly what the reviewer
needs so the GO is fast and rarely bounces.

This does NOT change review authority (the human gate is unchanged); it makes
the gate fast. It EXTENDS the existing implementer disciplines (smallest diff,
surfaces enumeration, written invariant, skeptic sub-agents, premise gate,
ground-truth anchor; see `docs/verification-disciplines.md`); it does not
replace them.

## The flow (implementer)

1. Build the smallest correct fix; run the skeptic sub-agents.
2. **Run an adversarial second-model pre-review BEFORE requesting human
   review**: a different model (or a review harness) over the diff. Fix what it
   flags. Attach its verdict to the PR body. The point is that the human
   reviewer should rarely be the first adversarial eye on the change.
3. Fill the packet template below as the PR body. Keep the diff small; if it is
   large, split it (a reviewer GOes on small diffs fast).
4. Only then request human review.

Goal metric: median human-review wait and bounce rate DOWN (see
`docs/goal-anchored-improvement.md`), exhaustiveness bar unchanged.

## PR-body template (copy, fill, delete the comments)

```markdown
Closes #<issue>

## Review in 5 minutes
- **Risk:** HIGH | LOW - <one line: data write? money/rate? auth/publish gate? schema/migration? or cosmetic/read-only/additive?>
- **Diff:** <N> files, +<add>/-<del>  <!-- small is the goal; split if large -->
- **2nd-model review:** <model/tool> - PASS | CHANGES-FOLDED - <one line: what it checked / what it caught>
- **Tests:** executed <unit | integration | staging cell> - PASS <link>
- **Before/after:** <one line + evidence link or screenshot of the live path>

## What changed
- <1-3 bullets, smallest correct diff; no adjacent refactor>

## Root cause (premise-gated)
<1-2 lines.> Live-path evidence: <link>  <!-- premise gate + ground-truth anchor: cite the real request/audit log, not a hand-built equivalent -->

## Surfaces touched
<write path / read path / response shape / DB column / downstream consumer - list each, or "none beyond the change above">  <!-- a fix that leaves the rest of a shared flow broken is what this catches -->

## Invariant  <!-- race / sort / positional bugs only; else "n/a" -->
<the invariant, enforced at the source, not patched at query time>

## Adversarial review
- Skeptic sub-agents: <N> - <verdict; what they tried to break and why it holds>
- Second-model pre-review (<model/tool>): <verdict>; folded: <what changed as a result>

## Test matrix
| cell | input | observed | expected | verdict |
|------|-------|----------|----------|---------|
| <happy path> | | | | |
| <each known variant / edge> | | | | |

## Evidence
- <links: evidence files, audit-log capture, staging run, screenshots>
```

## Risk classification (one line, but get it right; it sets review depth)

HIGH = data writes; money, amounts, rates; publish/approve/reject/auth gates;
production config; schema or migration; anything irreversible or affecting many
users. LOW = cosmetic, additive-only display, isolated read-only, a change
behind an off flag. When in doubt, HIGH.

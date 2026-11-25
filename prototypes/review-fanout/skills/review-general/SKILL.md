---
name: review-general
description: General code review lens - correctness, regressions, API design, missing tests.
---

# General review

Review the change for:

- Correctness bugs: wrong logic, off-by-one, unhandled error paths, broken edge cases.
- Regressions: behavior that used to work and no longer does.
- API design: confusing or inconsistent interfaces introduced by the change.
- Missing tests for new or changed behavior.
- User-facing behavior changes that are not called out.

Report only real, actionable defects with concrete evidence and an exact code pointer.
No praise, summaries, speculation, style preferences, or nice-to-have refactors.

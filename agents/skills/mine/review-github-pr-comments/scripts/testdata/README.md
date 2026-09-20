# Test data for triage.mjs

Captured 2026-09-19 during the triage-script evaluation
(../../docs/triage-eval-2026-09-19.md). Fixtures are `--fixture`-mode inputs
with known ground truth. Pure logic (policy gates, skip logic, excerpt
coordinates, hunk splitting) is covered by `../triage.test.mjs`
(`npm test`); these fixtures are for manual end-to-end replay against the
live model, e.g. after prompt or evidence-model changes.

- `pr2697-full-evidence.json` — PR #2697's 3 Copilot threads with coherent
  post-fix evidence (headRefOid=4c96d48a, post-fix diff, branch commits).
  Ground truth: thread 1 fixed near anchor (auto already_handled), thread 2
  fixed ~120 lines away (already_handled suggestion, escalates), thread 3
  needs process evidence (low-confidence fix, escalates).
- `pr2697-prefix-threads-head-code.json` — same threads, pre-fix diff
  (deliberately stale vs. code), no commits. Expect thread 1 to wobble
  around the auto-accept gate: evidence incoherence degrades verdicts.
- `pr2697-coherent-postfix.json` — post-fix diff, no commits.
- `synthetic-noise-gate.json` — question-phrased genuine concern (must
  escalate), praise (auto noise), withdrawn request (auto noise).
- `synthetic-softer-question.json` — same concern, no suggested fix (must
  escalate).
- `probe-file-absent-at-commit.json` — thread on `app.log`: exists in the
  gitops-k8s working tree, absent at the pinned commit; verifies the
  coordinate fix yields a no-excerpt placeholder, not a working-tree read.

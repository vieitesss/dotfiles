# Issue 0001: Jev triage in review-github-pr-comments

**Skill:** `~/.agents/skills/mine/review-github-pr-comments/SKILL.md`
**Pattern:** verify-and-escalate. Jev triages every review point cheaply; low-confidence or `fix` points escalate to the big model.

## Problem

Steps 4–5 of the skill (normalize feedback, decide fix/reject/defer/already-handled) are repeated snap judgments over comment text + current code, done ad hoc by the big LLM on every run. On PRs with dozens of bot comments (CodeRabbit, Copilot, Qodo), this is slow and expensive for what is mostly a classification task.

## Proposed Jev judgments

State per review point: comment thread text, the diff hunk it anchors to, current file content around it, PR title/body.

| ID | Type | Question |
|---|---|---|
| `decision` | Choice | fix / reject / defer / already-handled — what should happen with this point? |
| `stale` | Noul | Is this comment still true in the current code? |
| `addressed` | Noul | Does the current branch already resolve this concern? |
| `duplicate_of` | Noul (pairwise) | Do these two points describe the same issue? |

All four asked in one parallel request per point. Escalation rule: confidence below threshold, or `decision=fix`, goes to the big model for final judgment and implementation.

## Integration shape

A script (run by the agent in step 4) that fetches threads via `gh`, builds state per point, calls Jev, and emits a triage table. The agent then works only the escalated set.

## Status: tier 1 built

Tier 1 implemented as `scripts/triage.mjs` (Node, `@typesafe-ai/sdk`) in the skill directory, wired into SKILL.md step 4. Per unresolved thread it asks `actionable` (Noul), `already_addressed` (Noul), and `decision` (Choice: fix/reject/defer/already_handled) in one parallel request, with state = latest reviewer message + full thread + diff hunks near the anchor + current-code excerpt (±40 lines) + PR title/body.

Decisions locked with the user:

- Escalation target: the big model in the same run (skill does the cycle end to end); the user is not asked.
- Auto-accept only `noise` (actionable < 0.5) and `already_handled` (choice + confidence ≥ 0.8 + addressed ≥ 0.8). `fix`/`reject`/`defer` always escalate.
- Exit 3 (no API key) / 4 (all calls failed) → skill falls back to fully manual steps 4–5.

Calibration from the first fixture run (5 synthetic threads against dotfiles `install.sh`): praise → noise 0.03; stale comment already acted on in-thread → noise 0.16 (the "later comments may withdraw" rule works); a true already-handled case picked `already_handled` but at conf 0.75 / addressed 0.76, just under the gate → escalated (safe direction); real bug → fix 0.97; rewrite suggestion → defer 0.95. Watch whether the 0.8 gate over-escalates true already-handled cases on real PRs before lowering it.

Deferred to later tiers: dedup (pairwise Noul), staleness, out-of-scope, severity Score, post-fix verification.

## Open questions

- Confidence threshold for auto-reject/auto-defer vs. escalate — needs calibration on real PRs.
- Does Jev have enough context from hunk + surrounding file, or does it need the whole diff?
- Who owns the final decision on `reject` — is Jev's `reject` ever auto-accepted, or always confirmed?

## Addendum 2026-09-19: first real-PR evaluation + fixes

Evaluated against prefapp/gitops-k8s#2697 (3 Copilot threads, manual ground
truth) plus synthetic probes — full report:
`agents/skills/mine/review-github-pr-comments/docs/triage-eval-2026-09-19.md`.

Verdict: keep, repositioned as re-review reaper + noise filter + evidence
pre-assembler. Never auto-accepted a wrong verdict in ~36 judged threads;
escalated suggestions were wrong when the deciding evidence was outside the
evidence model (0/2 on the ground-truth PR, both blind spots).

Changes applied to `scripts/triage.mjs` (19-test golden suite added,
`npm test` in `scripts/`):

- **Deviation from a locked decision**: auto-noise now requires
  `actionable < 0.2` (was `< 0.5`). Rationale: a false noise verdict
  silently discards real feedback — the script's worst failure mode — and
  the 0.5 gate had no margin. The 0.2–0.5 band now escalates. Revert to 0.5
  only with counter-evidence.
- **Latent bug fixed**: the diff-hunk regex captured hunk *headers only*;
  Jev never saw diff content in any prior run. Hunks are now split by line
  and ordered near-first, filling the 3000-char budget (answers "does Jev
  need the whole diff?": it needs the file's hunks ordered by proximity,
  which now actually arrive).
- **`pr.commits` added to state** (branch commit subjects+bodies) so
  `BREAKING CHANGE:` footers and similar process evidence are visible.
- Post-fix validation: the true already-handled thread stopped straddling
  the 0.8 gate (addressed 0.74–0.80 → 0.92–0.93, auto 3/3). The observed
  "threshold flapping" was mostly starving evidence, not a mis-set
  threshold — so the 0.8 already_handled gate is unchanged, pending logged
  real-PR data.
- Fixed two evidence-assembly bugs from the pre-eval session (repo
  detection JSON parse; excerpt coordinate system now reads the file at
  `headRefOid`, falling back to the working tree only when the commit is
  not fetched).

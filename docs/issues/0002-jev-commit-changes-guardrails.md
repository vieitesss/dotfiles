# Issue 0002: Jev guardrails in commit-changes

**Skill:** `~/.agents/skills/mine/commit-changes/SKILL.md`
**Pattern:** select-instead-of-generate + verification. Jev never writes commit messages; it groups, classifies, and verifies.

## Problem

Splitting changes into atomic groups by intent and picking a Conventional Commit type are repeated semantic judgments the big LLM does ad hoc. There is no check that the final one-line message actually matches the staged diff.

## Proposed Jev judgments

| ID | Type | Question | State |
|---|---|---|---|
| `commit_type` | Choice | feat / fix / docs / refactor / test / chore — which type is this diff? | diff per candidate group |
| `same_intent` | Noul (pairwise) | Do these two hunks serve the same logical change? | pair of hunks |
| `message_matches` | Noul | Does this one-line message accurately describe this diff? | message + staged diff |
| `has_secrets` | Noul | Does this diff contain a likely secret or sensitive value? | diff (reinforces the skip-secrets rule) |

`message_matches` is the highest-value one: a cheap pre-commit guardrail run on every group, flagging mismatches for regeneration.

## Integration shape

The skill's workflow step 2–3 gains a verification pass: after staging each group and drafting the message, run `message_matches`; below threshold → revise the message. `same_intent` assists the grouping step when the file set is large.

## Open questions

- Hunk granularity: pair hunks, files, or file-level groups as the `same_intent` unit?
- Threshold for `message_matches` — a false positive forces a regeneration loop; needs calibration.
- Is `has_secrets` better left to deterministic scanners (gitleaks-style)?

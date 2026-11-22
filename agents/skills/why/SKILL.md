---
name: why
description: "Answer why code is built this way from git history and PR discussions. Use for 'why does X work this way', 'why did we pick Y', design rationale, regressions, postmortems, or data-backed thresholds."
---

# Why

Answer from the record, not the code. Loaded by the Research Stage alongside `research` for in-repo history questions.

## 1. Trace the history

Locate the commits that introduced the target and each later change using `git log -L`, `git log -S`, `git log --follow`, and `git blame`. Read the full commit messages with `git show <sha>` rather than one-line summaries.

## 2. Read the PR discussion

Find the pull requests for those commits (`gh pr list --search <sha> --state merged` or PR numbers referenced in commits) and read their descriptions and review threads:

- `gh pr view <N> --comments`
- `gh api repos/{owner}/{repo}/pulls/<N>/comments`

Follow links from commits or PRs to ADRs, issues, or postmortems when the git trail is thin.

## 3. Report from the record

State the decisions, tradeoffs, and constraints the authors recorded.

- **Cite**: back every factual claim with a commit SHA, PR number, or linked doc path, plus a brief verbatim quote from what the authors wrote.
- **Separate inferences**: mark any deduction that goes beyond the written record with **Inference:** so facts and interpretation never blur.
- **Surface gaps**: write **no record** for any part of the question the history does not answer; leave silence visible instead of guessing from the code.

## Done when

- Every factual claim cites a commit SHA, PR number, or linked record with a quote.
- Every deduction beyond the text is labeled **Inference:**.
- Every unanswered part explicitly states **no record**.

---

*Adapted from pstack (`skills/why/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

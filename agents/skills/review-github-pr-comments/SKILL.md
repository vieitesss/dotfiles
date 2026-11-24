---
name: review-github-pr-comments
description: "Thread pass of `babysit`: triage one PR's review feedback to a verdict per point, fix the accepted ones, reply and resolve."
disable-model-invocation: true
---

# Review GitHub PR Comments

The thread pass `babysit` runs. It takes the PR number, the mode (`check`, `threads-only` or `drive`), and any reviewer filter from `babysit`. Run directly (`/skill:review-github-pr-comments`), use the user's PR or the current branch's (`gh pr view --json number`) and treat it as `check` unless the user asks for fixes.

Judge every point against the **current branch**: diff, code, and PR intent as they are now, never the original review snapshot. Refetch GitHub data at the start of every run; thread text goes stale as the branch moves.

## Verdicts

- `fix`: valid issue that belongs in this PR.
- `reject`: wrong, stale, speculative, purely stylistic without local support, or contradicted by current code, conventions, or PR goal.
- `defer`: reasonable, but follow-up work outside this PR.
- `already handled`: the current branch already resolves it.

## Steps

### 1. Understand the PR

Read the PR body, current diff (`gh pr diff`), branch commits, affected files and local conventions before judging any comment.

### 2. Fetch the feedback

Collect review summaries and inline threads from all authors, bots included, unless a reviewer filter was given. Read whole threads: the latest reviewer message plus the resolved/outdated state defines the current ask. Queries: `references/github-queries.md`.

### 3. Triage

From the repository root:

```bash
node <skill-dir>/scripts/triage.mjs
```

(`<skill-dir>` = this skill's directory; first run: `npm install` in `scripts/`; `--reviewers login,login` for a reviewer filter; `--help` for more. Exit 3/4 or missing `node`/`gh`: note it and triage every thread manually.)

`Auto:` verdicts are final; carry them into the report as-is. Jev fix/reject/defer suggestions are input, never the verdict. Jev sees only the thread, a ±40-line excerpt, the file's diff hunks, PR metadata and commit messages, so a confident `fix` can be an evidence blind spot: verify against the branch. Rationale and known limits: `docs/triage-eval-2026-09-19.md`.

Give a verdict to **every** escalated thread and every concrete point split from review summaries (summaries are context, not evidence: check each against the code). Collapse duplicates. If a point is ambiguous, state the ambiguity and ask one focused question.

Done when every point has a verdict. In `check`, skip to step 6.

### 4. Fix

Implement every `fix` fully, or report the concrete blocker:

- Re-read the relevant code first; match current code, not reviewer wording.
- Use `coding` for the smallest correct change; fold overlapping fixes into one change.
- Add or update tests when behaviour changes or a coverage gap closes.
- Verify with the most relevant checks available.
- If implementation shows the comment rested on a misunderstanding, change the verdict and say why.

Commit with `commit-changes` and push, so replies can cite a pushed SHA.

### 5. Reply and resolve

For each thread reviewed in this run: post a ≤2-line reply (`fix` → commit SHA + one-line summary; otherwise → the reason), then resolve it. Reply first so the closure records why. Commands: `references/github-queries.md`.

### 6. Report

```markdown
## Triage
- auto already handled: N — `path:line` list
- auto noise: N — `path:line` list
- escalated, decided below: N

## Verdicts
- fix|reject|defer|already handled — reviewer — `path:line` — reason

## Applied Changes
- `path` — comment: ... — change: ... — commit `sha`

## Verification
- `command` — result
```

---
name: review-github-pr-comments
description: Review GitHub PR comments and bot feedback, decide each point (fix, reject, defer, already handled), and apply accepted fixes on request.
---

# Review GitHub PR Comments

Triage PR feedback to a **verdict** per point, then act on it. Judge every point against the **current branch** — diff, code, and PR intent as they are now, never the original review snapshot. Refresh GitHub data at the start of every run; thread text goes stale as the branch moves.

## Verdicts

- `fix` — valid issue that belongs in this PR.
- `reject` — wrong, stale, speculative, purely stylistic without local support, or contradicted by current code, conventions, or PR goal.
- `defer` — reasonable, but follow-up work outside this PR.
- `already handled` — the current branch already resolves it.

## Workflow

### 1. Identify the PR

Use the user's PR number or URL, else infer from the current branch:

```bash
gh pr view --json number,url,title,body,baseRefName
```

No active PR: stop and report.

### 2. Understand the PR

Read the PR body, current diff (`gh pr diff`), and branch commits, plus the affected files and local conventions, before judging any comment.

### 3. Fetch the feedback

Collect review summaries and inline threads — all authors, bots included, unless the user named specific reviewers. Read whole threads: later replies often narrow or withdraw the original ask, so the latest reviewer message plus the resolved/outdated state defines the current ask. When `gh pr view` is not enough, use `references/github-queries.md`.

### 4. Triage

From the repository root:

```bash
node <skill-dir>/scripts/triage.mjs
```

(`<skill-dir>` = this skill's directory; first run: `npm install` in `scripts/`; `--reviewers login,login` when the user named reviewers; `--help` for more. Exit 3/4 or missing `node`/`gh`: note it and triage every thread manually.)

`Auto:` verdicts are final — carry them into the step-6 report as-is. Jev fix/reject/defer suggestions are input, never the verdict.

Jev's evidence is the thread, a ±40-line excerpt around the anchor, the file's diff hunks, PR metadata, and branch commit messages — no repo-wide context (conventions, CI, release tooling). A confident `fix` suggestion can be an evidence blind spot, not a conclusion; verify against the actual branch. Rationale and known limits: `docs/triage-eval-2026-09-19.md`.

Give a verdict to **every** escalated thread and every concrete point split from review summaries (summaries are context, not evidence — check each against the code). Collapse duplicates pointing at the same issue. Decide from current code and PR goal: is the problem real, in scope, still true, consistent with local conventions, safe to apply? If ambiguous, state the ambiguity and ask one focused question.

### 5. Implement fixes

Skip edits when the user asked only for review or triage. Otherwise implement every `fix` fully — or report the concrete blocker:

- Re-read the relevant file sections first; match current code, not reviewer wording.
- Use `/coding` for the smallest correct change; fold overlapping fixes into one coherent change.
- Add or update tests when behavior changes or a coverage gap closes.
- Verify with the most relevant checks available.
- If implementation proves the comment was based on a misunderstanding, change the verdict and explain why.

### 6. Report

```markdown
## PR Context
- Goal: ...
- Branch state: ...

## Review Summaries
- Reviewer: summary

## Triage
- auto already handled: N — `path:line` list
- auto noise: N — `path:line` list
- escalated, decided below: N

## Verdicts
- fix|reject|defer|already handled — reviewer — `path:line` — reason

## Applied Changes
- `path` — accepted comment: ... — implementation: ...

## Verification
- `command` — result
```

### 7. Resolve threads

Only when the user explicitly asks, or has already asked to commit and push. Per thread: post a ≤2-line reply (fixed → commit SHA + one-line summary; otherwise → the reason), then resolve — reply first so the closure records why. Resolve only threads reviewed in this run. Commands: `references/github-queries.md`.

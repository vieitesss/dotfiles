---
name: babysit
description: Babysit a GitHub PR to merge-ready across conflicts, review threads, and CI. Use for "babysit this PR", "get PR N merge-ready", "check PR N", or "review PR comments".
---

# Babysit

Own one PR's path to merge-ready; stop where a human call begins. Use `gh` for all GitHub operations and `git` for local fix commits.

## Mode

Declare the mode in your first line, before any query:

- `drive` — loop until merge-ready or blocked on a human call.
- `threads-only` — handle review threads only; leave CI alone. Pick this for "review PR comments".
- `check` — run one read-only status pass and report; change nothing.

Carry any reviewer filter the user names (e.g. only Copilot) into the thread pass.

## Pass order

Run every pass in strict order: **conflicts, then threads, then CI**. Re-read live PR state at the start of every pass:

```bash
gh pr view N --json number,url,state,isDraft,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

### 1. Conflicts

Check `mergeable` and `mergeStateStatus`. If `mergeable` is `CONFLICTING` (or `mergeStateStatus` is `DIRTY`), report the conflict naming `headRefName` (the branch that needs a rebase onto `baseRefName`, reconciling any trunk drift) and **stop**. Never rebase, retarget, or force-push, and do not fall through to CI.

### 2. Threads

Run the thread pass in [`../review-github-pr-comments/SKILL.md`](../review-github-pr-comments/SKILL.md) (resolve the path against this skill's directory), passing the PR number, the mode, and any reviewer filter. In `check` it gives verdicts without editing; in `drive` and `threads-only` it fixes, commits, pushes, then replies and resolves. In `threads-only`, report and stop after it.

Quick count of unresolved threads, for the status line and the exit check:

```bash
gh api graphql -f owner=OWNER -f repo=REPO -F pr=N -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes { id isResolved isOutdated path line comments(first: 1) { nodes { author { login } url } } }
      }
    }
  }
}' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
```

### 3. CI

Inspect `statusCheckRollup` and read failed logs with `gh run view <run-id> --log-failed`:

- **Pending:** wait (see Waiting).
- **Flaky or infra failure:** trigger at most one rerun with `gh run rerun <run-id> --failed`, then wait. If it fails again, report it and stop.
- **Diff failure:** fix locally, commit with `git`, push, and wait for the fresh run. Only failures caused by this diff get a commit.

In `check`, report each check's status without rerunning or committing.

## Reviewer loop

When the user asks to loop on a bot reviewer (e.g. "loop on Copilot reviews"), each round is one thread pass in a **fresh agent**: a new agent per round, never the previous round's agent continuing. A fresh agent judges the new comments without anchoring on its own earlier fixes or rejections, and stays inside one context window.

The orchestrator (the Manager, or you if you run alone) owns the loop between rounds:

1. Launch a fresh agent for the round's thread pass (`drive` or `threads-only`, with the reviewer filter). It fixes, pushes, replies, resolves, and stops. It never re-requests a review or waits for one.
2. Check its work, then close it.
3. Re-request the bot's review on the new head (Copilot: `gh pr edit N --add-reviewer "@copilot"`) and wait for it (see Waiting).
4. Stop when the new review on the current head adds no actionable comments, after 3 rounds, or when the bot does not respond within 30 minutes. Otherwise go to step 1.

Pass each fresh agent the threads its predecessors rejected, so it flags a repeated comment as a question instead of flipping the verdict.

## Waiting

Wait on running CI or external state with one background command that exits when the state changes, then end your turn so its completion notification resumes you for the next pass:

- Running workflow: `gh run watch <run-id> --exit-status`
- Other PR state: a single `until` loop over `gh pr view` with its own timeout

## Approval and exit

Owner approval (`reviewDecision != APPROVED`) and draft state (`isDraft == true`) are waits. Never merge on your own authority. Stop and report once the PR is merge-ready (clean, zero unresolved threads, green CI) or blocked on a human call, summarizing conflicts, threads, CI, approval state, and next action.

---

*Adapted from pstack (`skills/poteto-mode/playbooks/babysit.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

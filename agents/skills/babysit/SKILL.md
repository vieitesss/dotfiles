---
name: babysit
description: Babysit a GitHub PR to merge-ready across conflicts, review threads, and CI. Use for "babysit this PR", "get PR N merge-ready", "check PR N", or "handle PR threads".
---

# Babysit

Own one PR's path to merge-ready; stop where a human call begins. Use `gh` for all GitHub operations and `git` for local fix commits.

## Mode

Declare the mode in your first line, before any query:

- `drive` — loop until merge-ready or blocked on a human call.
- `threads-only` — handle review threads only; leave CI alone.
- `check` — run one read-only status pass and report; change nothing.

## Pass order

Run every pass in strict order: **conflicts, then threads, then CI**. Re-read live PR state at the start of every pass:

```bash
gh pr view N --json number,url,state,isDraft,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

### 1. Conflicts

Check `mergeable` and `mergeStateStatus`. If `mergeable` is `CONFLICTING` (or `mergeStateStatus` is `DIRTY`), report the conflict naming `headRefName` (the branch that needs a rebase onto `baseRefName`, reconciling any trunk drift) and **stop**. Never rebase, retarget, or force-push, and do not fall through to CI.

### 2. Threads

Fetch unresolved review threads:

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

In `check`, list unresolved threads and continue to CI. In `drive` and `threads-only`, hand them to `review-github-pr-comments`, pushing any fix commits before replying so replies cite the commit. In `threads-only`, report and stop here.

### 3. CI

Inspect `statusCheckRollup` and read failed logs with `gh run view <run-id> --log-failed`:

- **Pending:** wait (see Waiting).
- **Flaky or infra failure:** trigger at most one rerun with `gh run rerun <run-id> --failed`, then wait. If it fails again, report it and stop.
- **Diff failure:** fix locally, commit with `git`, push, and wait for the fresh run. Only failures caused by this diff get a commit.

In `check`, report each check's status without rerunning or committing.

## Waiting

Wait on running CI or external state with one background command that exits when the state changes, then end your turn so its completion notification resumes you for the next pass:

- Running workflow: `gh run watch <run-id> --exit-status`
- Other PR state: a single `until` loop over `gh pr view` with its own timeout

## Approval and exit

Owner approval (`reviewDecision != APPROVED`) and draft state (`isDraft == true`) are waits. Never merge on your own authority. Stop and report once the PR is merge-ready (clean, zero unresolved threads, green CI) or blocked on a human call, summarizing conflicts, threads, CI, approval state, and next action.

---

*Adapted from pstack (`skills/poteto-mode/playbooks/babysit.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

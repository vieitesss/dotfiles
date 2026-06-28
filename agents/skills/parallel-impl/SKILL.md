---
name: parallel-impl
description: Implement multiple user-authored plans in parallel, each on its own branch off the current branch in a separate git worktree and tmux pane running pi, then merge them all back. Use when the user wants to "implement these in parallel", "parallelize these plans", "fan out these handoffs", or build several plans at once in the same branch lineage.
disable-model-invocation: true
---

# Parallel implementation across worktrees

Run N user-authored plans concurrently: one branch + one git worktree + one
tmux pane (running `pi`) per plan, all branched off the current branch. After
launch, hand control back to the user. When they say "merge", merge every branch
back into the base branch sequentially, resolving conflicts automatically.

Requires: running inside a `tmux` session. The user supplies the plan file
paths (and optionally branch names) at invocation.

## Phase 1 — Confirm the base and the mapping

1. Get the current branch: `git rev-parse --abbrev-ref HEAD`.
2. **Ask the user to confirm this is the branch to branch off from.** Do not
   proceed until confirmed.
3. Warn (don't block) if the base has uncommitted changes
   (`git status --porcelain`) — worktrees branch from the committed HEAD, so
   uncommitted work in the base is NOT included.
4. Build the `(branch ← plan)` mapping. Default branch name = plan filename
   slug (`auth-refactor.md` → `auth-refactor`). Resolve every plan path to an
   absolute path. Show the mapping and base branch, and confirm with the user.

## Phase 2 — Launch

Pick a worktree root next to the repo, e.g. `../<repo>-worktrees`.

Run the launcher with the confirmed base, the worktree root, and one
`branch=abs-plan-path` argument per task:

```bash
scripts/launch_panes.sh <base-branch> <worktree-root> \
  auth-refactor=/abs/path/auth-refactor.md \
  cache-layer=/abs/path/cache-layer.md
```

It creates each worktree (`git worktree add -b <branch> <dir> <base>`), opens a
tmux pane per worktree, and launches `pi @<plan> "<implement+commit prompt>"`
in each.

**Then STOP.** Tell the user the panes/branches are running and that you will
merge once they confirm the implementations are done. Do not poll, do not
guess — wait for the user's explicit "merge".

## Phase 3 — Merge (only after the user says to merge)

Merge sequentially into the base branch. The first merge is always clean;
conflicts appear from the second branch on because they touch the same files.

For each branch in order, from the base worktree (the original repo dir):

```bash
git checkout <base-branch>
git merge --no-ff <branch>
```

On conflict, resolve it yourself — you hold every plan, so you know the intent
behind each side. Read `resolving-merge-conflicts` skill for the mechanics if
needed. Reconcile the conflicting hunks honoring both plans, `git add` the
resolved files, and commit the merge. Only stop and ask the user if two plans
**semantically contradict** each other (not just textual overlap).

Commit everything: each branch's work is already committed in its worktree;
each merge (including conflict resolutions) is committed automatically.

## Phase 4 — Cleanup and report

1. Remove the worktrees: `git worktree remove <dir>` for each.
2. **Keep the branches** (don't delete) so merged work stays recoverable until
   the user confirms.
3. Report: which branches merged cleanly, which had conflicts, and how each
   conflict was reconciled.

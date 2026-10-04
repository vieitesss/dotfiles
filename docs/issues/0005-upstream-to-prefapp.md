# Issue 0005: move proven skills to prefapp/skills

Revisit once the Manager workflow (`docs/workflow.md`) has been used for a while.

## Candidates

- **Debt axis** → prefapp `review`, as a third read-only axis beside Standards and Spec. Today it lives only in our Review Stage.
- **`coding`** → prefapp workflow, as the Build-time behaviour guide.
- **`zero-tech-debt`** → prefapp workflow, as the Refine skill (vendored, MIT).

## Staying here

`manager`, `subagents`, `update-subagents`: they depend on herdr/tmux, pi, and Jev, which coworkers do not use.

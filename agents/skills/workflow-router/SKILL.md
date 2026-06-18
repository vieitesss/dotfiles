---
name: workflow-router
description: Repository workflow router. Use before non-trivial repo work (features, bug fixes, refactors, architecture review, or design work). Chooses company SDD when a `specs/` directory contains documentation, lightweight workflow when `CONTEXT.md` exists, otherwise asks the user.
---

# Workflow Router

Before non-trivial repo work, detect workflow mode.

## Detection

Find repo root with `git rev-parse --show-toplevel`, falling back to cwd.

1. If any `specs/` directory contains documentation files (`*.md`, `*.mdx`, `*.rst`, `*.txt`, `*.adoc`) → use SDD.
2. Else if root `CONTEXT.md` exists → use `/lightweight-development-workflow`.
3. Else ask the user: SDD or lightweight.
   - If lightweight: create root `CONTEXT.md` from `/context-modeling`, then use `/lightweight-development-workflow`.
   - If SDD: use local `development-workflow` if present.

If both `specs/` docs and `CONTEXT.md` exist, SDD wins. Still read `CONTEXT.md` and ADRs as project context.

## SDD mode

If `.agents/skills/development-workflow/SKILL.md` exists, read it and follow it exactly.

If SDD is detected but no local `development-workflow` skill exists, stop and ask whether to:

- follow generic SDD,
- switch to lightweight,
- or stop until repo setup is fixed.

## Narrow edits

For direct narrow edits with an exact target and no design uncertainty, decide "no workflow needed" and proceed normally.

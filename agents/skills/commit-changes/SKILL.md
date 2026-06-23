---
name: commit-changes
description: Create conventional, one-line commits from current git changes, splitting work into the smallest sensible atomic commits. Use when the user asks to commit changes.
---

## What I do
Inspect repo state, split changes into the smallest atomic groups by intent, and commit
each group with a one-line Conventional Commit message.

## Rules
- Only run this workflow after an explicit user request to commit changes.
- Push changes only when the user explicitly requests a push.
- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:` — scope optional
- One logical change per commit; never mix unrelated changes
- Split independent fixes, features, docs, tests, refactors — combine only when tightly coupled
- One-line messages ONLY (no body)
- Do NOT add yourself as co-author
- Skip secrets/sensitive files (e.g., `.env`)

## Workflow
1. Run `git status`, `git diff`, recent `git log`
2. Identify smallest safe atomic groups
3. Stage each group and commit
4. Repeat until all relevant changes are committed
5. Show `git status` and summarize commits

## Apply valid comments
- If you find that the any of the valid comments requires asking the user because it
changes the structure design of the code, use `/grill-with-docs` and ask the user.
- Any other valid comments can be applied using `/coding`.

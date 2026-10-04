---
name: commit-changes
description: Create conventional, one-line commits from current git changes, splitting work into the smallest sensible atomic commits. Use when the user asks to commit changes.
---

# Commit changes

- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`
  — scope optional.
- One logical change per commit. Split independent fixes, features, docs, tests,
  and refactors; combine only when tightly coupled. You own grouping from the
  diffs.
- One-line messages only (no body).
- Do not add yourself as co-author.
- Leave secrets and sensitive files unstaged (`.env`, keys, credentials). The
  guard's local pattern screen is a backstop, not exhaustive detection.

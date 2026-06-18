---
name: context-modeling
description: Lightweight project context and ADR maintenance. Use when creating or updating `CONTEXT.md`, recording design choices as ADRs, or when another workflow needs project vocabulary, commands, pitfalls, or design memory without full SDD.
---

# Context Modeling

Maintain lightweight project memory. Not specs. Not domain maps.

## CONTEXT.md

Root `CONTEXT.md` shape:

```md
# Project Context

## Purpose
- What this repo is for.

## Vocabulary
- **Term**: Meaning. Avoid: wrong/old names.

## Commands
- Test:
- Lint:
- Run:

## Pitfalls
- Things agents often get wrong.

## ADRs
Design decisions live in [docs/adr/](docs/adr/).
```

Keep it short. Prune stale bullets. Do not list every ADR path.

## ADRs

ADRs live in `docs/adr/0001-slug.md`.

Write ADRs for design choices:

- module shape
- seam/interface placement
- data ownership
- dependency/technology choice
- persistent tradeoff
- rejected design direction with load-bearing reason

Skip ADRs for implementation details:

- renamed function
- moved file
- obvious bug fix
- local refactor with no design tradeoff

Format:

```md
# Short decision title

We decided X because Y. Main tradeoff: Z.
```

1-3 paragraphs. No rich template unless useful.

Write/update docs as decisions happen. If implementation changes the design, patch the ADR/context immediately.

---
name: review-debt
description: The Debt axis of a Review, run read-only by a Review Subagent.
---

> **Before acting:** read any root `AGENTS.md` / `CLAUDE.md` and obey it: repo rules override this skill.

The Debt axis asks one question of a Change Set: does it leave the code
carrying more history than its intended shape needs? It sits beside the
Standards and Spec axes of `review`; the Fowler smells belong to Standards,
so this axis hunts **cruft**: compatibility paths, versioned twins, stale
flags, pass-through layers, and abstractions with one caller.

You only read. Every fix goes to a later Refine Subagent, so a finding has to
carry everything Refine needs to act on it.

## Scope

The brief gives the diff command and the commit list. Your scope is:

1. **Added debt**: cruft the diff itself introduces.
2. **Touched debt**: cruft in the functions and modules the diff edits.

Cruft elsewhere is out of scope for findings. List it under Follow-ups, one
line each, so the Manager can open new Work Items for it.

## Hunt

Walk [`../zero-tech-debt/references/04-audit-patterns.md`](../zero-tech-debt/references/04-audit-patterns.md)
over the scope, pattern by pattern, with its searches narrowed to the touched
files. Judge each candidate against the anti-patterns in
[`../zero-tech-debt/references/05-decision-filters.md`](../zero-tech-debt/references/05-decision-filters.md).

Every candidate is a judgement call. Find its callers before you call
something dead; keep anything a documented repo rule, a live caller, or an
in-flight migration still needs, and skip whatever tooling already enforces.

## Report

Write to the report file the launcher names, under 400 words:

- **Findings**, one per candidate: pattern name, `file:line`, the quoted
  hunk, added or touched, and the shape-change Refine should make (delete,
  inline, rename, or merge) in one sentence.
- **Follow-ups**: out-of-scope cruft, one line each.
- **Clean**: the patterns you walked that found nothing, so the Manager sees
  the axis was covered.

The axis is done when every pattern in the audit list has been walked over
the scope and each one appears under Findings or Clean.

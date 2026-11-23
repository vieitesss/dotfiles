---
name: blast-radius
description: Blast radius analysis that finds what a change could break outside its diff and proves its safety fact by running real code. Use for "blast radius of X", "what could this break", "is this safe to merge", or reviewing a risky change.
---

# Blast radius

*Adapted from pstack (`skills/blast-radius/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

Find what a change could break outside its diff before it ships, and prove the one fact it is safe because of by running real code. A convincing writeup proves nothing on its own; run the code and show the result.

## Proof levels

Push every safety fact as far down this ladder as is cheap, and report where it stopped:

- `stated` — asserted without checking code; proves nothing on its own.
- `cited` — pointed at a real `file:line` or dependency source.
- `walked` — traced the failure path step by step and showed it cannot reach.
- `ran` — executed a script, command, or test against the real code that fails loud if wrong.
- `reproduced` — exercised the behaviour end-to-end in the running system.

## Steps

1. **Read the change.** Inspect the full diff, commits, and PR context: symbols added, changed, or deleted, plus implicit behaviour changes (defaults, side effects, timing, config).
2. **Name the one safety fact.** Identify the single fact the change's safety depends on. If it holds, most downstream risks clear at once; focus legwork here before listing edge cases.
3. **Trace past grep.** Follow what a symbol search misses: indirect callers, downstream consumers, config and manifests, data or wire formats, pinned library source and local patches, execution order (teardown, async, hooks), and other repos or symlinks that link this one. Cite real `file:line` for every claim; record an empty search explicitly.
4. **Separate confirmed and cleared risks.** Rate each confirmed risk by real likelihood and impact. List checked areas that hold separately with their proof level.
5. **Prove the safety fact.** Run real code — a read-only command, test, or minimal script calling the exact implementation — that fails loud if the fact is false, and capture the command and output. Mark the fact `unproven` if you cannot run it, and report the highest level reached.

## Writeup

Hand back these four sections with every claim grounded in real code or command output:

- **Safety fact & proof level** — the one fact, its proof level (`stated` / `cited` / `walked` / `ran` / `reproduced`, or `unproven`), and the exact command and output.
- **Confirmed risks** — how each breaks, `file:line`, likelihood and impact, and how to trigger it.
- **Cleared risks** — each checked surface, why it is safe, and its proof level.
- **Cheapest pre-merge check** — the smallest command, test, or repro that catches the real bug before merge.

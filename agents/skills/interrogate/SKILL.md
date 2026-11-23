---
name: interrogate
description: "Adversarial review for the Review break axis: try to break a change by running it and report only findings proven by rerunnable command output."
disable-model-invocation: true
---

# Interrogate

Act as an adversary on the Review `break` axis. Try to break the change by running it against the real code. A finding survives only when a command you ran proves the failure.

Leave repo files untouched: keep any scratch state in a command-scoped temp directory so the worktree stays clean. You are the sole Subagent on this axis; run every probe yourself and return your report through the launcher's report file and recado instructions.

## 1. Frame

Read the brief for the diff command, diff base, worktree, and spec. Run the diff command to inspect the change, then state the intent in one or two sentences from the spec and commits. Target runtime behavior and contracts: edge cases, boundary inputs, error paths, state transitions, and regressions against the intent.

Then follow steps 2–3 of [`../blast-radius/SKILL.md`](../blast-radius/SKILL.md) (resolve the path against this skill's directory): name the one safety fact and trace the change past grep. Add every outside-the-diff consumer you find to the attack list. Report in this skill's format, not blast-radius's.

## 2. Attack

Exercise the changed code directly from the worktree root: run tests, invoke commands or functions with adversarial inputs, hit error paths, and probe integration seams.

Every finding's command must be **self-contained and rerunnable** from a clean worktree root without prior shell state, repo edits, or pre-existing temp files (use inline invocations such as `sh -c`, `python3 -c`, or existing test commands). The Manager reruns each finding's command before accepting it; any command that fails to reproduce cold is dropped.

Finish attacking only when every changed behavior, risky boundary, and traced outside-the-diff consumer has been probed or noted as unreachable in this environment.

## 3. Filter

Keep a finding **only** when a command you ran produced output showing a failure that breaks the intent.

- **Verified finding**: carries the exact command, its actual output, and the output the intent requires.
- **Root cause**: collapse multiple repros of the same underlying bug into one finding with the cleanest command.
- **Not proven**: place any suspicion you could not prove by running a command — including unreachable paths or environment-blocked checks — in a short separate **Not proven** list, never as a finding.
- **Out of scope**: omit style, naming, structure, and risks that require a future change to matter; other Review axes cover those.

## 4. Report

Write the report file with these sections:

- **Intent**: one-to-two-sentence statement of what the change must do.
- **Findings**: for each verified finding:
  - **Title**: concise description of the failure.
  - **Command**: exact, self-contained command rerunnable from the worktree root.
  - **Actual**: verbatim output printed (and exit code when non-zero).
  - **Expected**: the output or behavior the intent requires.
  When nothing breaks, write **no verified findings**.
- **Attacks tried**: concise list of the probes and cases run (always include this, especially when no verified findings survive).
- **Not proven**: short list of unproven suspicions and why they could not be proven ("none" if empty).

---

*Adapted from pstack (`skills/interrogate/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

---
name: arena
description: "Run competing Build Subagents for one Work Item, cross-judge against a rubric, pick a base, and graft the strongest parts. Use for /arena, or when a Work Item admits several valid shapes or is a one-way door."
disable-model-invocation: true
---

# Arena

Manager procedure for a Work Item that admits several valid shapes or is a one-way door. Competing Build Subagents solve the same brief in separate worktrees, a read-only judge scores them, and a fresh Build Subagent grafts the strongest parts onto the winning base.

Use `subagent` and `recado` for every launch and message (see the `subagents` skill). Every code edit goes to a Subagent; the Manager never edits code.

## 1. Frame

Before launching anything:

1. Write one shared brief (the artifact spec, constraints, and checkable done criteria) to a scratch file, instructing each candidate to note alternatives considered and rejected in its report. Candidates see only the brief; reserve the rubric for the judge and your pick.
2. Write a 3–6 item rubric of concrete, gradeable criteria for this Work Item.
3. Choose at least two candidates on distinct Harnesses (`pi`, `agy`, `claude`, `opencode`), each with its own worktree and branch cut from the same diff base.

Done when the brief, rubric, and candidate worktrees exist.

## 2. Fan out

Launch one Build Subagent per candidate with a distinct `--item`, distinct `--harness`, and its own worktree:

```bash
subagent launch --stage build --item <item>-<label> --harness H [--model M] \
  --cwd <candidate-worktree> < BRIEF_FILE
```

- Stagger launches to keep at most two concurrent builds per provider.
- Record each candidate's `name`, `window`, and worktree in the Ledger, then end your turn and wait for `TASK COMPLETE`.
- If a candidate produces no usable output, note the dropout and continue with the rest (at least two).

## 3. Cross-judge

After all candidates finish, launch one read-only ad-hoc judge (omit `--stage`) on a vendor no candidate used:

```bash
subagent launch --item <item>-judge --harness H --model M < JUDGE_BRIEF
```

Give the judge the rubric, the diff base, and every candidate's worktree path (by label) and report path (absolute paths). Instruct it to stay read-only, inspect each candidate's diff, run each candidate's tests for evidence when useful, score every candidate criterion-by-criterion against the rubric with evidence, and name a recommended base.

## 4. Pick a base

Read every candidate's diff and report end to end, score against the rubric yourself, and compare with the judge's report:

- Agreement confirms the pick; disagreement means reading both rationales before deciding.
- Prefer the base a future maintainer can extend most cleanly without breaking invariants.
- If candidates converge on one shape, take the consensus base and skip Graft. If they diverge wildly, reframe the brief and re-run.

## 5. Graft

Launch a fresh `--stage build` Subagent on the picked base's worktree to integrate the strongest parts of the losers (typically one or two focused ideas per loser, folded cleanly into the base's mental model):

```bash
subagent launch --stage build --item <item>-graft --cwd <base-worktree> < GRAFT_BRIEF
```

Point the brief at the base worktree, the losing worktrees (absolute paths), the judge's report, and the exact grafts to port and verify. Require a **synthesis note** in the graft's report covering:

- picked base and why (including judge verdict, convergence, or dropouts);
- each graft and its source candidate;
- what was rejected from losers and why;
- verification result with a `Verdict:` line.

If verification catches a flaw a loser avoided, send a follow-up to graft it; if it exposes a spec gap, reframe and re-run.

## 6. Review and clean up

- Run the normal Manager **Review** loop on the base worktree (see the `manager` skill).
- Close remaining candidate and judge windows (`subagent close WINDOW`), and remove losing worktrees and branches once the graft is accepted.

---

Adapted from [pstack](https://github.com/cursor/plugins/tree/main/pstack) by Lauren "poteto" Tan, licensed under the MIT License.

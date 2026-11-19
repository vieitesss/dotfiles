---
name: manager
description: Run the session as the Manager for implementation: split the goal into Work Items, delegate every Stage to a fresh Subagent, accept or send back each report, and own the final report.
disable-model-invocation: true
---

# Manager

You own the session: the conversation with the user, every decision, the
acceptance of each Subagent's work, and the final report.

You always delegate implementation. A Subagent makes every edit, even a
one-line fix. You may read files, run tests and lint, and merge finished
branches. You never edit repo files; the Ledger and brief files are session
files outside git.

Each Subagent runs one Stage of one Work Item in its own Rex window. The
`subagents` skill documents the CLI (`subagent stages`, `subagent launch`,
`subagent close`) and the messages. This skill does not repeat it.

## Start

1. Read `.agents/ledger.md` at the main checkout's root before any other
   fetch. If it exists, you are resuming: take up each Work Item at the Stage
   and status it records. Pull only what the Ledger leaves open, with narrow
   queries: `gh issue view N --json body,state`,
   `gh pr view N --json state,headRefName,statusCheckRollup`. Fetch comments
   only when the Ledger or the body points to one.
2. Otherwise split the goal into Work Items, size them (see Sizing), and write
   the Ledger before any Stage runs.

## Stages

Each Work Item passes through these Stages in order. Run a Stage when its
trigger holds; skip it otherwise.

| Stage    | Run when                                                                 |
| -------- | ------------------------------------------------------------------------ |
| Research | the work hinges on facts outside the repo: APIs, docs, specs             |
| Build    | the Work Item changes code                                               |
| Write    | the Work Item is prose: docs, skills, agent instructions                 |
| Refine   | Build reshaped an existing module, or Review returned Standards or Debt findings. Skip for new code, hotfixes, security backports, and small fixes |
| Review   | after every round that wrote code (Build or Refine); see Review          |

`subagent stages` prints each Stage's skills and model. Name the Stage in a
brief, never its skills.

Refine runs on the code the Work Item touched, after Build's tests pass. Rot
beyond that code becomes a new Work Item.

## Ledger

`.agents/ledger.md` at the main checkout's root is the session's memory. It
outlives `/clear`, compaction, a handoff, and resuming on another device. The
`git/ignore` manifest keeps it and `.agents/reports/` out of git. Hand-edit it
from the template in `LEDGER_EXAMPLE.md`.

- **Subagent**: the name and window that `subagent launch` printed, while the
  Subagent is open. Write `-` once you close it.
- **Status**: `running` when launched; `question` when a Subagent sends a
  Question; `blocked on user` when a decision waits on the user; `done` when
  the last Stage is accepted.
- **Stage**: on acceptance, move the row to its next Stage and set `running`
  when you launch that Stage.
- **Decisions**: one line each, with the answer and its date.

Update the Ledger at every change: a launch, a Question, an acceptance, a user
decision.

Handing the session to another Manager goes through the `handoff` skill. Its
document and the Ledger are the whole handover.

## Sizing a Work Item

A Subagent that compacts has lost part of its brief. Size every Stage to
finish in one context window: one module, or three to five related fixes, with
a brief under about 60 lines. Split anything larger into Work Items, each with
its own Ledger row, before you launch. Work Items that share a worktree run in
series.

## Briefs

A Subagent starts cold: its brief is everything it knows. Write each brief to
a scratch file, then launch:

```bash
subagent launch --stage S [--axis A] --item I --cwd WORKTREE < BRIEF_FILE
```

It prints the name, window, block, and report path. Record the name and window
in the Ledger. The brief carries:

- the Work Item, the goal, and what you already know: symptom, repro,
  `file:line`, earlier reports;
- where: worktree path, branch, diff base, and what to leave alone. The
  Subagent commits its work on that branch;
- the two or three files it needs, and what it must not read. "Read the whole
  module" spends its context before it edits;
- the cheapest fix that meets the acceptance criteria, naming any existing
  tool or script that covers part of it. New machinery needs a Question first;
- a checkable done criterion: named tests, lint, pass counts (`10/10`);
- the decisions it brings back as a Question instead of making.

Never put a report path in the brief; launch adds it. Stages hand over through
files: the next brief points at the previous report, the diff base, and the
worktree.

## Parallel Work Items

Work Items on disjoint code run in parallel, one worktree each. Work Items that
overlap run in series in one worktree. At most one Subagent edits a worktree at
a time; read-only Stages (Research) may share one. Create each worktree before
you launch into it, and pass its path as `--cwd`.

Merge a branch into main yourself once its Work Item's Review loop is clean.

## Review

Run Review after every round that wrote code, Build or Refine. Never after
Write. Each round gets fresh Subagents, one per axis:

1. Take the fixed point, spec source, and standards sources from steps 1 to 3
   of the `review` skill. Do this yourself.
2. Launch one Subagent per axis, in parallel, with the Work Item as `--item`
   (`batch`, not `batch-review`):
   - `--axis spec` always;
   - `--axis standards` and `--axis debt` when the change spans several modules
     or reshapes one.
   Each brief carries the diff command, the commit list, and the spec or
   standards sources.
3. Present the reports side by side.

Loop until no findings remain. Group findings by file or theme, at most five
per group. Each group is its own Work Item, must-fix groups first: Spec groups
go to Build, Standards and Debt groups to Refine. Each fix round gets a fresh
Subagent whose brief points at the previous report, the diff base, and the
worktree; its fix gets a fresh Review round.

Ask the user, and mark the Work Item `blocked on user`, when a finding needs
their decision, comes back after its fix, or disputes the spec itself.

## Accepting returned work

- A Question, or a message proposing an approach, is a decision. Answer it
  (`recado reply`, see `subagents`), or ask the user and record their answer
  under Decisions.
- On TASK COMPLETE, read the report and the diff. Spot-check its evidence by
  running the tests it names. Run anything over a minute in its own background
  call, then end your turn.
- Before acceptance, a failed spot-check or a missing piece goes as a follow-up
  to the same Subagent (`recado send NAME`, see `subagents`). It answers with a
  fresh TASK COMPLETE, read again as above.
- A report that mentions compaction, or that dropped part of the brief, means
  the Work Item was too big. Split what is left across fresh Subagents instead
  of a follow-up.
- Fresh Subagents are for each Stage and for each fix round born from Review
  findings (see Review), never for a follow-up on an unaccepted report.
- On acceptance, once the evidence checks out: `subagent close WINDOW`, set the
  Ledger's Subagent cell to `-`, and move the row to its next Stage.

## Waiting on outside state

A CI run, a deploy, or a sandbox render is waited on like a Subagent. Start one
background command that exits when the state arrives (`gh run watch
--exit-status`, or an `until` loop with its own timeout), then end your turn.
Its completion notification resumes you. Where the harness has a Monitor tool,
use it for a state that changes more than once.

## Report

Every status update, and the final report, lists the branches not yet merged
into main and what each waits on; "none" when all are merged. The final report
tells the user what changed and where, how it was proven, which Stages you
skipped and why, what is uncommitted, and which decisions are still theirs.
It points at the Ledger for the full record.

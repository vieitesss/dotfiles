---
name: manager
description: "Run the session as the Manager for implementation: split the goal into Work Items, delegate every Stage to a fresh Subagent, accept or send back each report, and own the final report."
disable-model-invocation: true
---

# Manager

You own the session: the conversation with the user, every decision, the
acceptance of each Subagent's work, and the final report.

You always delegate implementation. A Subagent makes every edit, even a
one-line fix. You may read files, run tests and lint, and merge finished
branches. You never edit repo files; the Ledger and brief files are session
files outside git.

Each Subagent runs one Stage of one Work Item in its own Rex window, whether
the Manager or Subagent runs on `pi`, Claude Code, OpenCode, or `agy`. Always
delegate through `subagent launch` and communicate through `recado` — never
through a harness's built-in subagent, swarm, or messaging tools (such as
`agy`'s `invoke_subagent`, `swarm`, or `send_message`). The `subagents` skill
documents the CLI (`subagent stages`, `subagent launch`, `subagent close`) and
the messages. This skill does not repeat it.

## Start

1. Read `.agents/ledger.md` at the main checkout's root before any other
   fetch. If it exists, you are resuming: take up each Work Item at the Stage
   and status it records. Pull only what the Ledger leaves open, with narrow
   queries: `gh issue view N --json body,state`,
   `gh pr view N --json state,headRefName,statusCheckRollup`. Fetch comments
   only when the Ledger or the body points to one.
2. Otherwise, in your first message, restate the user's goal and the smallest
   change that meets it. Write both as the Ledger's `Goal:` line, then split
   the goal into Work Items, size them (see Sizing), and finish the Ledger
   before any Stage runs.

## Stages

Each Work Item passes through these Stages in order. Run a Stage when its
trigger holds; skip it otherwise.

| Stage    | Run when                                                                                   |
| -------- | ------------------------------------------------------------------------------------------ |
| Research | the work hinges on outside facts like APIs, docs, and specs, or in-repo history via `why`  |
| Build    | the Work Item changes code, or fixes findings returned by Review                           |
| Write    | the Work Item is prose: docs, skills, agent instructions                                   |
| Refine   | Build reshaped an existing module and its tests pass, or the user asks for a cleanup pass  |
| Review   | after Build or Refine; see Review                                                          |
| Retro    | conducting a read-only retrospective of a session, writing one report                      |

`subagent stages` prints each Stage's default harness, model, effort and skills.
Name the Stage in a brief, never its skills. Keep every Stage on its configured
`subagent stages` profile unless the user explicitly specifies a harness, model,
or effort — pass those through with `--harness`, `--model`, and `--effort`, and
record session-wide overrides in the Ledger's Decisions. Never swap models on
your own for rate limits; stagger launches instead.

Refine is a standalone `zero-tech-debt` cleanup pass on an existing Work Item
diff (`diff base != HEAD`), never a clean branch and never a fix round for
Review findings. Skip it for new code, hotfixes, security backports, and small
fixes. Rot beyond the touched code becomes a new Work Item.

## Ledger

`.agents/ledger.md` at the main checkout's root is the session's memory. It
outlives `/clear`, compaction, a handoff, a restart, and resuming on another
device. The `git/ignore` manifest keeps it, `.agents/handoff.md`,
`.agents/briefs/`, and `.agents/reports/` out of git. Edit it with
your file-edit tools (`edit` / `write` / `edit_file` / `write_file`, not shell
scripts) from the template in `LEDGER_EXAMPLE.md`. When starting a new goal,
archive or clear completed rows and stale decisions from earlier goals so the
Ledger holds only the active goal. Once more than 10 rows accumulate, archive
merged rows into a single `Merged: ...` summary line so `edit` stays trivial
and shell or Python scripts are never needed.

- **Subagent**: the name and window that `subagent launch` printed, while the
  Subagent is open. Write `-` once you close it.
- **Status**: `running` when launched; `question` when a Subagent sends a
  Question; `blocked on user` when a decision waits on the user; `done` when
  the last Stage is accepted. Cap the cell at 200 characters; put detail in
  the report and point to it from the cell.
- **Stage**: on acceptance, move the row to its next Stage and set `running`
  when you launch that Stage.
- **`## Decisions`**: one line each, with the answer and its date. Check this
  section before asking the user anything.
- **`## Open questions to user`**: write a pending question here before asking
  the user. Remove the line once answered and move the answer to
  `## Decisions`.
- **`## Operations`**: date each line and prune it when the fact stops holding.

Update the Ledger at every change: a launch, a Question, an acceptance, a user
decision.

Handing the session to another Manager goes through the `handoff` skill. Save
its document as `.agents/handoff.md` beside the Ledger, not in `$TMPDIR`: a
restart empties the temporary directory. That document and the Ledger are the
whole handover.

## Sizing a Work Item

A Subagent that compacts has lost part of its brief. Size every Stage to
finish in one context window: one module, or three to five related fixes, with
a brief under about 60 lines. Split anything larger into Work Items, each with
its own Ledger row, before you launch. Work Items that share a worktree run in
series.

## Briefs

A Subagent starts cold: its brief is everything it knows. Write each brief to
`.agents/briefs/ITEM-STAGE.md` at the main checkout's root with your
file-write tool (`write` / `write_file`, not a shell heredoc), then launch.
Never write it under `/tmp` or `$TMPDIR`: a restart empties them, and the
Ledger's pointers then lead nowhere.

```bash
subagent launch --stage S [--axis A] --item I --cwd WORKTREE \
  [--harness H] [--model M] [--effort E] < BRIEF_FILE
```

It prints the name, window, block, and report path. Record the name and window
in the Ledger. The brief carries:

- the Ledger's `Goal:` line first, then the Work Item and what you already know:
  symptom, repro, `file:line`, earlier reports;
- where: worktree path, branch, diff base, and what to leave alone. The
  Subagent commits its work on that branch;
- the two or three files it needs, and what it must not read. "Read the whole
  module" spends its context before it edits;
- the cheapest fix that meets the acceptance criteria, naming any existing
  tool or script that covers part of it. New machinery needs a Question first;
- a checkable done criterion: named tests, lint, pass counts (`10/10`); every
  fix brief states a checkable repro for each must-fix finding;
- the decisions it brings back as a Question instead of making.

Never put the new report path in the brief; launch adds it. Point Write briefs
for human-facing docs, such as READMEs and PR bodies, at the `technical-writing`
skill. Stages hand over through files: point the next brief at earlier reports
using **absolute paths** (worktrees have no `.agents/reports/` directory), the
diff base, and the worktree.

## Parallel Work Items

Work Items on disjoint code run in parallel, one worktree each. Work Items that
overlap run in series in one worktree. At most one Subagent edits a worktree at
a time; read-only Stages (Research, Review, Retro) may share one. Run at most
two concurrent builds per provider, or stagger launches, to avoid rate limits.
Create each worktree before you launch into it, and pass its path as `--cwd`.

Merge a branch into main yourself once its Work Item's Review loop is clean.
When a merged Work Item is one part of a split parent issue that stays open,
post a one-line comment on the parent issue stating what landed so parallel or
triage sessions see live state.

## Arena

When a Work Item admits several valid shapes or is a one-way door, follow the
`arena` skill to run competing Build Subagents, cross-judge them, and graft the
strongest parts onto the chosen base.

## Review

Run Review after Build, and after Refine when Refine ran. Never after Write or
Retro. Each round gets fresh Subagents, one per axis:

1. Take the fixed point, spec source, and standards sources from steps 1 to 3
   of the `review` skill. Do this yourself.
2. Launch one Subagent per axis, in parallel, with the Work Item as `--item`
   (`batch`, not `batch-review`):
   - `--axis spec` always;
   - `--axis break` in parallel with `--axis spec` when the diff changes
     runtime behaviour, not docs, config, or renames;
   - `--axis standards` and `--axis debt` in parallel with `--axis spec` when
     the change spans several modules or reshapes one; keep separate axes
     rather than collapsing them into `--axis spec`.
   Each brief carries the diff command, the commit list, and the spec or
   standards sources.
3. Rerun the command behind each `--axis break` finding before accepting it,
   and drop any finding you cannot reproduce. Present the reports side by side.

Group accepted findings by file or theme, at most five per group. Every fix
group goes to **Build** (Spec, Standards, and Debt alike), must-fix groups
first, in a fresh Subagent whose brief points at the review report, the diff
base, and the worktree. Pre-existing bugs that already behaved the same on
`main` (not regressions of this diff) become a separate follow-up Work Item
instead of blocking the merge.

Run **one** verification Review whenever a fix round addressed must-fix
findings, scoped strictly to whether the fix diff resolved the original
findings without regressing them (do not skip it on multi-file fixes, and never
launch `r3`/`r4` Review rounds). If that verification Review still returns
findings:

- **Non-blocking findings:** create one follow-up issue listing them and merge.
- **Merge-blocking findings:** run at most one targeted final Build round and
  verify each reported repro yourself before merging; if any repro still fails,
  create one follow-up issue and mark the Work Item `blocked on user`.

Ask the user, and mark the Work Item `blocked on user`, whenever a finding
needs their decision, blocks merge after verification, or disputes the spec
itself.

## Accepting returned work

- A Question, or a message proposing an approach, is a decision. Answer it
  (`recado reply`, see `subagents`), or ask the user and record their answer
  under Decisions. Reversible implementation choices belong in the report's
  "Choices made" section for review, not as Questions.
- On TASK COMPLETE, read only the report's opening summary block with
  `sed -n '1,/^## /p' REPORT`. Every Stage report opens with a summary block
  of at most 10 lines: `Verdict`, what changed, must-fix count, and decisions
  needed. Open the rest of the report only when the summary block points
  there. Inspect the diff, and rerun the command behind the Build `Verdict`
  and the tests the report names. Never accept `INCONCLUSIVE` or a
  wrong-surface check as done. Run anything over a minute in its own
  background call, then end your turn.
- Turn each line in a report's "Pre-existing" section into a follow-up Work
  Item or issue instead of launching a fix round.
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

Follow the `ketchup` skill to write status updates and the final report
decision-first:

1. Open with one sentence naming what waits on the user, or "nothing".
2. List one line per Work Item with what changed and its `Verdict`.
3. List every call waiting on the user with your pick, the evidence, and the
   risk.
4. List branches not yet merged into main and what each waits on, or "none"
   when all are merged, plus skipped Stages and why, and any uncommitted work.

Point at the Ledger for the full record.

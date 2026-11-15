---
name: manager
description: Run the session as the Manager, moving Work Items through Stages, delegating to Subagents when it pays, and owning the report.
disable-model-invocation: true
---

# Manager

You own the session: the conversation with the user, every decision, the
acceptance of each Subagent's work, and the final report. Subagents run one
Stage of one Work Item each, launched through the `subagents` skill in a Rex
window, here or on another Rex host; they never manage.

## Start

1. Read `.agents/ledger.md` at the repo root, before any other fetch. If it
   exists, you are resuming: take up each Work Item at the Stage and status
   it records. Then pull only what the Ledger leaves open, with narrow
   queries: `gh issue view N --json body,state`,
   `gh pr view N --json state,headRefName,statusCheckRollup`. Fetch comments
   only when the Ledger or the body points to one.
2. Otherwise Shape the goal if it is open, split it into Work Items, and write
   the Ledger before any Stage runs.

## Stages

Every Work Item passes through these Stages in order. Run a Stage when its
trigger holds, skip it otherwise, and record the skip in the Ledger.

| Stage    | Run by                                  | Run when                                                         |
| -------- | --------------------------------------- | ---------------------------------------------------------------- |
| Shape    | you, with `grilling`                    | the goal or approach is open and a wrong guess is costly         |
| Research | Subagent                                | the work hinges on facts outside the repo (APIs, docs, specs)    |
| Design   | you with the user; Subagent to prototype | a state model, UI, or module interface is undecided             |
| Plan     | the user: suggest `to-spec`, `to-tickets`, `wayfinder` | the work outgrows one session                     |
| Diagnose | Subagent                                | a bug's cause is unknown                                         |
| Build    | Subagent                                | the Work Item changes code                                       |
| Write    | Subagent                                | the Work Item is prose: docs, skills, agent instructions         |
| Refine   | a fresh Subagent, running `zero-tech-debt` | Build reshaped an existing module, or Review returned Standards or Debt findings; skip it for new code, hotfixes, security backports, and small fixes |
| Prove    | you; Subagent for `verify-<app>`        | always, scaled by the proof budget                               |
| Review   | one Subagent per axis it needs          | the proof budget says so, once per Change Set                    |
| Ship     | you, with `commit-changes`, `visual-pr` | the user asks, and Review's loop is clean when its trigger holds |

`subagent --stages` prints the skills and model each Subagent Stage loads;
the Stage decides them, so a brief names the Stage, never skills.

Refine runs on Build's green tests and before Prove, over the code the Work
Item touched; rot beyond that becomes a new Work Item. Its brief still names
`zero-tech-debt`, so the round is never a plain edit.

A Work Item that is a few known lines in one or two files skips straight to
Build, and you build it yourself. Prove it with scoped lint and tests, then
read your own diff. It still gets its Ledger row.

Read an existing file before you Write over it, above all in a worktree
outside the session's directory, and write to a symlink's target.

## Ledger

`.agents/ledger.md` at the main checkout's root is the session's memory. It
outlives `/clear`, compaction, a handoff, and resuming from another device.
Preparing a Stage keeps it, and the reports beside it, out of git. In the
Subagent column keep the name and the Rex window `launch` printed, plus the
host for a remote Stage: follow-ups and closing need them.

```md
# Ledger

Goal: <one line>
Mode: serial | parallel worktrees | review per PR

| Item       | Stage  | Status   | Subagent                              | Worktree / branch       | Report                              |
| ---------- | ------ | -------- | ------------------------------------- | ----------------------- | ----------------------------------- |
| login-form | build  | running  | subagent-build-4123 window:7f3a       | ../app-wt/login (login) | .agents/reports/login-form-build.md |
| session    | refine | accepted | subagent-refine-4188 rpi window:91c2  | ~/src/app (login)       | .agents/reports/session-refine.md   |

## Decisions
- login-form: keep the legacy cookie name (user, 2026-10-04).

## Skipped Stages
- login-form: Research, no outside facts.
```

Status is one of `queued`, `running`, `question`, `accepted`, `blocked on
user`, `done`. Update the Ledger at every change: a Stage starts, a Question
arrives, you accept a report, the user decides. Edit table rows with
`ledger set ITEM COLUMN VALUE` and `ledger add ITEM COLUMN=VALUE...`; write
Decisions and prose by hand. `ledger` and `subagent` are manifest links in
`~/.local/bin`; on a machine without them, run
`~/.agents/skills/manager/scripts/ledger.py` and
`~/.agents/skills/subagents/scripts/subagent.py` with `python3`.

Handing the session to another Manager goes through the `handoff` skill: its
document and the Ledger are the whole handover. Name in it the screenshots
the user shared; Claude Code keeps them under
`/private/tmp/claude-501/<project>/<session>/images/`.

## Do it or delegate it

Do the work yourself by default. Do it yourself when:

- the answer is already in context, or one lookup away;
- the Work Item is on the trivial path;
- writing the brief would take longer than doing the work;
- the user is waiting on a quick answer;
- the work is a decision, an acceptance, or needs the whole conversation.

Delegate when:

- the Stage needs its own edit-test loop over many steps;
- research means reading many sources and you need only the conclusion;
- independent Work Items can run in parallel;
- the work would flood your context (long logs, big diffs, repeated runs);
- a fresh model should look at it (Review, a second opinion).

Delegating hands off the legwork, never the decisions: a Subagent that hits a
choice sends a Question, and you answer. Beyond the trivial path, a diff you
built yourself still gets a fresh `--axis standards` reviewer before Ship.

Every Stage, and every fix round, gets a fresh Subagent. Until you accept a
report, follow-ups go to the Subagent that wrote it; once you accept, close
its window. Stages hand over through files: the next brief points at the
previous report, the diff base, and the worktree.

## Briefs

A Subagent starts cold: its brief is everything it knows. Write each brief to
a scratch file. It carries:

- the Work Item, the goal, and what you already know (symptom, repro,
  `file:line`, earlier reports);
- where: worktree path and branch, the diff base, and what to leave alone;
- the cheapest fix that meets the acceptance criteria, naming any existing
  tool or script that covers part of it; new machinery needs a Question first;
- a checkable done criterion: named tests, lint, pass counts (`10/10`);
- the decisions it brings back as a Question instead of making.

Never put a report path in the brief: preparation adds the one report path.

## Loops over Work Items

Default: Work Items run one after another in one worktree, and Review runs
once over the whole Change Set. Switch the Ledger's mode when:

- **parallel worktrees**: Work Items touch disjoint code. One worktree and one
  editing Subagent each; merge each branch into main yourself once Refine and
  Prove pass. Review runs once, over the merged Change Set.
- **review per PR**: each Work Item ships as its own PR and gets its own
  Review. Stack (`gh-stack`) only when its code builds on another's.

At most one Subagent edits a worktree at a time; read-only Stages share one.

## Proof budget

- Always: lint and the tests scoped to what changed, the full suite once at
  the end, and your own read of the final diff.
- `verify-<app>`: when the change alters what a user sees or does and the
  tests do not observe it. Once, on the finished change.
- Review: once per Change Set that adds behaviour, spans several modules, or
  touches an interface, stored data, or security. Docs, renames, config, and
  small fixes a test already pins go without it.
- A report with passing evidence is proof already: spot-check one claim.

## Review

Run the `review` skill's steps 1 to 3 yourself, then launch one read-only
Subagent per axis in parallel, with the Change Set as `--item` (`batch`, not
`batch-review`): `--axis spec` always; `standards` and `debt` too when the
Change Set spans several modules or reshapes one. Put the diff command,
commit list, and spec or standards sources in each brief. Present the reports
side by side.

Loop until no findings remain: Spec findings go to a fresh Build Subagent
first, then Standards and Debt findings to a fresh Refine Subagent. Re-check
each fix alone. Never offer Ship while a Change Set's Review trigger holds and
its loop is not clean.

Ask the user, and mark the Work Item `blocked on user`, when a finding needs
their decision, returns after its fix, or disputes the spec itself.

## Accepting returned work

- A Question, or a message proposing an approach, is a decision: answer it,
  or ask the user and record their answer under Decisions.
- On TASK COMPLETE, read the report and the diff, and spot-check the evidence
  with the tests it names. Run anything over a minute in its own background
  call, then end your turn.
- Then accept, or send a follow-up and wait for a fresh TASK COMPLETE that
  covers it.
- On acceptance, close the Subagent's window and move the Work Item to its
  next Stage in the Ledger.

## Waiting on outside state

A CI run, a deploy, or a sandbox render is waited on like a Subagent: start
one background command that exits when the state arrives (`gh run watch
--exit-status`, or an `until` loop with its own timeout), then end your turn.
Its completion notification resumes you. Where the harness has a Monitor
tool, use it for a state that changes more than once.

## Report

Every status update, and the final report, lists the branches not yet merged
into main and what each waits on; "none" when all are merged. Tell the user
what changed and where, how it was proven, which Stages you skipped and why,
what is uncommitted, and which decisions are still theirs. Point at the
Ledger for the full record.

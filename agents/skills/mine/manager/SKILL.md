---
name: manager
description: Run a work session as the manager — do quick work yourself, delegate the rest to subagents, review what they return, and own the report. Use when told to act as the manager.
---

# Manager

You own the session: the conversation with the user, every decision, the
review of delegated work, and the final report. Subagents do legwork you hand
off through the `subagents` skill; they never manage.

## Workflow

Every piece of work passes through these stages. Each one costs time and
tokens: run a stage when its trigger holds and skip it otherwise.

| Stage    | Skills                                     | Run when                                                         |
| -------- | ------------------------------------------ | ---------------------------------------------------------------- |
| Shape    | `grilling`                                 | the goal or approach is open and a wrong guess is costly         |
| Research | `research`                                 | the work hinges on facts outside the repo (APIs, docs, specs)    |
| Design   | `prototype`, `codebase-design`             | a state model, UI, or module interface is undecided              |
| Plan     | `to-spec`, `to-tickets`, `wayfinder`       | the work outgrows one session; these are user-invoked, so suggest them |
| Build    | `implement` with `tdd`; `diagnosing-bugs`  | always, for a change; `diagnosing-bugs` when the cause is unknown |
| Refine   | `zero-tech-debt`                           | Build added behaviour or reshaped a module; not for hotfixes, security backports, or small fixes |
| Prove    | lint, tests, `verify-<app>`                | always, scaled by the proof budget                               |
| Review   | `review`                                   | the proof budget says so                                         |
| Ship     | `commit-changes`, `visual-pr`, `review-github-pr-comments` | the user asks                                    |

A concrete, small ask goes straight to Build.

Refine runs once Build's tests pass and before Prove and Review, so
`verify-<app>` and `review` see the final shape once and cleanup never costs a
second review round. Scope it to the code the change touched: rot it finds
beyond that becomes a follow-up task, not part of this change. When a feature
would otherwise be bolted onto debt, run it before Build instead, as its own
change.

## Proof budget

Proof stages are the expensive ones: `review` runs two models, `verify-<app>`
drives the whole app, and each round costs minutes and the user's attention.
Spend them where a defect would be costly and the cheap checks cannot see it.

- Run lint and the tests scoped to what changed on every change, and the
  full suite once at the end. These are cheap and always run.
- Read the final diff yourself once before reporting: the cheapest review.
- Run `verify-<app>` when the change alters what a user sees or does and the
  tests do not observe it. Drive the recipe of the touched feature only, once,
  on the finished change.
- Run `review` once per finished change set that adds behaviour, spans
  several modules, or touches an interface, stored data, or security. Docs,
  renames, config, and small fixes a test already pins go without it.
- After fixing a finding, check that fix alone; the rest of the proof stands.
- A child's report with passing evidence is proof already: spot-check one
  claim (re-run the named test, open one evidence file) rather than redo it.

## Do it or delegate it

Do the work yourself by default. Delegate only when a delegate trigger holds.

Do it yourself when:

- the answer is already in context, or one lookup away (a file, a command,
  `--help`);
- the change is small and its shape is known: a few lines in one or two files;
- writing the brief would take longer than doing the work;
- the user is waiting on a quick answer;
- the work is a decision, a review, or anything that needs the whole
  conversation.

Delegate when:

- implementing or debugging needs its own edit-test loop over many steps;
- research means reading many files or sources and you need only the
  conclusion;
- independent pieces can run in parallel;
- the work would flood your context (long logs, big diffs, repeated runs);
- a fresh model should look at it (critique, review).

Delegating hands off the legwork, never the decisions: a child that hits a
choice asks, and you answer.

## Briefs

A child starts cold: its brief is everything it knows. Write each brief to a
scratch file and pass it as `"$(cat FILE)"`. It carries:

- the goal, plus what you already know (symptom, repro, `file:line`), so the
  child builds on it instead of re-deriving it;
- the skills to follow, by stage (`--skill implement --skill tdd`);
- where: worktree path and branch, and what it must leave alone;
- a checkable done criterion: named tests, lint, pass counts (`10/10`), and a
  `verify-<app>` proof when the budget calls for one;
- the deliverable: a report file path, and no commit;
- the decisions it brings back as a QUESTION instead of making.

`implement` ends with `review`; tell an implementing child to stop before it.
Review is yours to schedule. When Refine applies, add `--skill zero-tech-debt`
and have the child run it over the code it touched once its tests pass, then
stop.

## Parallel children

- One worktree per implementing child; two children never edit the same
  checkout. Read-only research children can share one.
- Untracked project skills (`.agents/skills/…`) are missing from a fresh
  worktree; give the child their absolute path in the main checkout.

## Reviewing returned work

- A QUESTION, or a progress message that proposes an approach, is a decision:
  answer it with `--notify` and end your turn.
- On TASK COMPLETE, read the diff and spot-check the evidence. Then accept, or
  send a follow-up and wait for a fresh TASK COMPLETE.
- Check that the next report covers your follow-up; one sent just as the
  child finished can go unread. Apply a missed small change yourself,
  otherwise send it again.
- Close the child's tab once you accept its work.

## Report

Tell the user what changed and where (branch, worktree), how it was proven,
which stages you skipped and why, what is uncommitted, and which decisions are
still theirs.

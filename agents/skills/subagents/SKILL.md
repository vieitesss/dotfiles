---
name: subagents
description: Launch a Subagent for one Stage of a Work Item in its own session, exchange messages with it, and close it. Use when the Manager delegates a Stage.
---

Launch one Subagent per Stage in its own Rex window. Message it over recado
until you accept its report, then close its window.

`subagent` is a link in `~/.local/bin`. Without it, run
`bash ~/.agents/skills/subagents/scripts/subagent` instead.

## Launch

```bash
subagent stages                  # each Stage, its skills and model

subagent launch --stage STAGE [--axis AXIS] --item ITEM \
  [--cwd DIR] [--model ROLE] < BRIEF_FILE
```

- `--stage` picks the Stage's skills and model.
- `--axis` applies to `review` only: `spec`, `standards` or `debt`.
- `--item` names the Work Item. Leave the Stage name out: `batch`, not `batch-review`.
- `--cwd` defaults to the current directory. Create the worktree first and pass its path.
- `--model ROLE` swaps in another role (`builder`, `writer`, `critic`) when a model fails the Stage.
- The brief goes on stdin. The launcher adds the tag, report path and recado commands.

Launch prints JSON `{name, window, block, report}`. Keep `name` and `window`.
`report` is `.agents/reports/<item>-<stage>[-<axis>].md` in the main checkout,
suffixed `-r2`, `-r3`, ... automatically if a prior report already exists.

Launch exits non-zero before anything runs when the Stage's skill is not
installed for `--cwd`. It also exits non-zero when the agent dies in its first
3 seconds, and prints the window's tail. A failed launch leaves its window
open: run `subagent close WINDOW` before you relaunch.

## Messages

Every message from a Subagent starts with its tag,
`[subagent-<stage>-<pid> · <item> · <stage>[ <axis>]]`. Use it to tell which
Work Item, Stage and axis the message concerns.

- `TASK COMPLETE: <summary>`: the Stage is done. Read the report file for detail.
- `QUESTION: <question>`: the Subagent waits for your answer. Reply with
  `recado reply ID "ANSWER"`, using the ID from the question.

Send a follow-up with `recado send NAME "MESSAGE"`, using the `name` from
launch. Each follow-up earns a fresh TASK COMPLETE.

## Waiting

After a launch or a message, end your turn. The Subagent's next message
resumes you and is the only signal to act on. Do not read its session status
or message queue.

A Subagent can stall on an approval only the user can give. It waits in its
window: tell the user to answer it there.

## Close

Once you accept the report, run `subagent close WINDOW`. That can come right
after TASK COMPLETE.

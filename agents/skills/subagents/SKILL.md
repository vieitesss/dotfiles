---
name: subagents
description: Launch one or more Subagents in their own Rex windows — either for a Manager Stage or ad-hoc on any supported harness, model, and thinking effort — exchange messages over recado, and close them.
---

Launch each Subagent in its own Rex window. Message it over recado until you
accept its report, then close its window.

Always use `subagent` and `recado` even if your harness has its own built-in
subagent, swarm, or messaging tools (such as `agy`'s `invoke_subagent`, `swarm`,
or `send_message`).

`subagent` is a link in `~/.local/bin`. Without it, run
`bash ~/.agents/skills/subagents/scripts/subagent` instead.

## Harnesses

`recado` and `subagent` work across four harnesses once `recado skill setup`
has installed each harness's hooks or shim (for `agy`,
`~/.gemini/config/hooks.json` and `~/.gemini/config/skills/recado`):

| Harness    | `--model` format                        | `--effort` flag passed                |
| ---------- | --------------------------------------- | ------------------------------------- |
| `pi`       | `<provider>/<model>`                    | `--thinking <effort>`                 |
| `agy`      | `<model>` (e.g. `gemini-4-neon-high`)   | `--effort <effort>` (`--mode auto`)   |
| `claude`   | alias (`opus`, `sonnet`) or full id     | `--effort <effort>` (`--permission-mode auto`) |
| `opencode` | `<provider>/<model>` (or `#variant`)    | none (encode variant in `--model` if supported) |

- `subagent`, `recado`, `gh`, and commands targeting sibling worktrees (`git`
  or package-manager commands outside the main checkout) reach state outside
  the workspace. On a sandboxed Harness such as `agy`, run those commands
  outside the sandbox directly rather than retrying after a sandbox denial.

## Launch

```bash
subagent stages                  # each Stage, its default harness, model, effort and skills

subagent launch [--stage STAGE [--axis AXIS]] --item ITEM [--cwd DIR] \
  [--harness HARNESS] [--model ROLE|MODEL] [--effort EFFORT] < BRIEF_FILE
```

- `--stage` picks the Stage's skills, role prompt, and default Model profile
  (`subagent stages` lists all Stages, including `retro`). Omit `--stage` for
  an ad-hoc Subagent with no Stage skills injected (defaults to the `builder`
  profile unless overridden).
- `--axis` applies to `--stage review` only: `spec`, `standards`, `debt`, or
  `break`. The `break` axis loads `interrogate` instead of `review`.
- `--item` names the Work Item or ad-hoc task. Leave the Stage name out:
  `batch`, not `batch-review`.
- `--cwd` defaults to the current directory. Create the worktree first and pass
  its path.
- `--harness` overrides the harness: `pi`, `agy`, `claude`, or `opencode`.
- `--model` accepts either a role (`builder`, `writer`, `critic`) to swap the
  whole Model profile (harness, model, and effort), or a harness-appropriate
  model id to override only the model.
- `--effort` overrides the thinking effort: `off`, `minimal`, `low`, `medium`,
  `high`, `xhigh`, or `max`. Explicit `--harness` and `--effort` override even
  when `--model ROLE` is also passed.
- The brief goes on stdin. The launcher adds the tag, report path and recado
  commands.

To run multiple Subagents in parallel, call `subagent launch` once per Subagent
with a distinct `--item` and keep each returned `name` and `window`. For judged
multi-harness comparisons on one Work Item, use the `arena` skill.

Example ad-hoc launches:

```bash
subagent launch --item cmp-claude --harness claude --model opus --effort high < brief.md
subagent launch --item cmp-agy --harness agy --model gemini-4-neon-high --effort medium < brief.md
subagent launch --item cmp-pi --harness pi --model github-copilot/gpt-6.2-sol --effort high < brief.md
subagent launch --item cmp-oc --harness opencode --model anthropic/claude-sonnet-4-5 < brief.md
```

Launch prints JSON `{name, window, block, report}`. Keep `name` and `window`.
`report` is `.agents/reports/<item>-<stage>[-<axis>].md` (or
`.agents/reports/<item>.md` for ad-hoc launches) in the main checkout, suffixed
`-r2`, `-r3`, ... automatically if a prior report already exists. Stage reports
include "Choices made" and "Pre-existing" sections; Build reports end with a
`Verdict: VERIFIED | NOT VERIFIED | INCONCLUSIVE` line and the command and
output behind it.

Launch exits non-zero before anything runs when a Stage's skill is not
installed for `--cwd`, or when `--harness`, `--model`, or `--effort` is invalid.
It also exits non-zero when the agent dies in its first 3 seconds, and prints
the window's tail. A failed launch leaves its window open: run
`subagent close WINDOW` before you relaunch.

## Messages

Every message from a Subagent starts with its tag:
`[subagent-<stage>-<pid> · <item> · <stage>[ <axis>]]` for Stage launches, or
`[subagent-adhoc-<pid> · <item>]` for ad-hoc launches. Use it to tell which
Subagent and task the message concerns.

- `TASK COMPLETE: <summary>`: the task is done. Read the report file for detail.
- `QUESTION: <question>`: the Subagent waits for your answer. Reply with
  `recado reply ID "ANSWER"`, using the ID from the question.

Send a follow-up with `recado send NAME "MESSAGE"`, using the `name` from
launch. Each follow-up earns a fresh TASK COMPLETE.

## Waiting

After a launch or a message, end your turn. The Subagent's next message
resumes you and is the only signal to act on. Check `recado inbox` only on
session start, after compaction, or on a user-initiated turn — never in empty
poll loops, and never by reading another Subagent's session status.

A Subagent can stall on an approval only the user can give. It waits in its
window: tell the user to answer it there.

## Close

Once you accept the report, run `subagent close WINDOW`. That can come right
after TASK COMPLETE.

`close` also stops what the Subagent left running: the processes still alive in
its window's process tree, with a working directory inside its worktree — the
git worktree of the launch directory, so a launch from a subdirectory still
covers the whole worktree — get SIGINT, then SIGTERM after 3 seconds if they are
still there, and each is printed with its pid and command. A process that moves
out of the worktree during those 3 seconds is printed, never signalled. Anything
else in that worktree — another Subagent, your own checks — is left alone, and
so is a Subagent launched in the main checkout, where `close` says it is not
reaping. If Rex refuses the close, `close` prints the error, keeps the record
and stops nothing.
A window that is already gone still closes cleanly. The tree is what Rex
reports, so a process reparented to init before `close` runs is not in it and
survives: that leftover is a known limit, not a reaping bug.

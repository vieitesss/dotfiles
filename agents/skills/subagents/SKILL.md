---
name: subagents
description: Launch a Subagent for one Stage of a Work Item in its own session, exchange messages with it, and close it. Use when the Manager delegates a Stage.
---

Launching is the Manager's move: the `manager` skill decides when to delegate
and what a brief carries. A Subagent runs one Stage and reports; the prepared
prompt already tells it so.

Two parts do the work. `scripts/subagent.py` prepares the Stage the same way on
every host: it validates the Stage, picks the model and effort, and prints one
JSON launch spec whose `prompt` carries the Stage role, skills, report path and
how to reach you. A host extension, a Markdown file you read, starts the
session from that spec.

**Before preparation**, read [`extensions.md`](extensions.md) and the chosen
host file. Choose for the Manager's conversation, not for the shell executing
the command. A Manager on a Mac can launch a Stage on an RPi; that RPi's tmux
pane is not the Manager's address. Follow the host file's remote-session
instructions when the machines differ.

```bash
SKILL=~/.agents/skills/subagents

python3 "$SKILL/scripts/subagent.py" --stages     # Stages, skills, models

spec=$(python3 "$SKILL/scripts/subagent.py" \
  --stage STAGE [--axis AXIS] --item ITEM \
  --cwd DIR --extension "$SKILL/extensions/HOST.md" \
  --manager MANAGER_ADDRESS [--model ROLE|ID] \
  "$(cat BRIEF_FILE)")
```

`--cwd` defaults to the current directory. `--dry-run` prints the same spec
without creating the report directory or editing `.git/info/exclude`, so it
runs anywhere.

## Extensions

The chosen host file gives the launch, follow-up and close commands, and what
the Subagent runs to reach you. A file anywhere else works as an `--extension`
too, including a per-session file holding a remote return route.

`--manager` is required: your own native address on the Manager's host. The
extension and address travel in the prompt. Prepare on the Stage's machine so
`--cwd`, skill paths, report path and `--extension` are readable there; a Mac
path does not identify an RPi file. For Paseo across machines, use the
[remote-session instructions](extensions/paseo.md#remote-sessions).

## Stage and profile

`--stage` decides the Subagent's skills and instructions; Review also takes
`--axis`. A Stage that pins a model (Write, Review) uses it; for the rest,
Jev picks the model, and Jev picks the thinking effort for every Stage.
`--model` overrides both the pin and Jev's pick with a role from `--stages` or
a `provider/model` id; use it when a model fails a Stage. Jev
needs `TYPESAFE_API_KEY`; without it preparation uses the default model and its
default effort. A `claude-code/<model>` model starts Claude Code instead
of Pi; the extension maps the spec's engine, model and effort onto its host.

Preparation fails before anything launches when a Stage's skill is not
installed for `--cwd`, when its `SKILL.md` sets
`disable-model-invocation: true`, or when `--extension` is missing or not a
file. Prove loads the repo's `verify-*` skills, so it needs at least one.

## Reports

Each Subagent writes its full report to
`.agents/reports/<item>-<stage>[-<axis>].md` in the main checkout, even when
it works in a worktree, and sends a one-line TASK COMPLETE pointing at it.
The spec's report path wins over any path in the brief. Keep `--item`
free of the Stage name (`batch`, not `batch-review`).
A Stage is finished only when all three are true: the report file is
written, the TASK COMPLETE has gone out through the extension's reporting
command, and the send is confirmed delivered (the Paseo helper names a
delivery log ending in DELIVERED; the other hosts report synchronously).
Send in the same turn the work finishes, before any summary to the user:
a written report with no confirmed send is still an open Stage.
Preparation adds `.agents/ledger.md` and `.agents/reports/` to the repo's
`.git/info/exclude`.

A fresh worktree holds tracked files only. Preparation also finds untracked
project skills (`.agents/skills/…`) in the main checkout and hands every
Subagent its skills by absolute path.

To work in a worktree, create it first, then pass its path as `--cwd`; the
extension says where its host puts the session.

## Messages

Every message starts with the Subagent's tag,
`[subagent-<stage>-<pid> · <item> · <stage>[ <axis>]]`, so you always know
which Work Item, Stage, and axis it is about. Preparation fills the tag into
the prompt; the spec's `tag` holds it. The extension says how messages
travel:

- `[…] TASK COMPLETE: <summary>`: the Stage is done; the report file holds
  the detail.
- `[…] QUESTION: <question>`: it waits for your answer.

Any other tagged message that asks for a choice is a question too. Answer, or
send a follow-up after a report, with the extension's follow-up command. A
follow-up earns a fresh TASK COMPLETE.

## Waiting

After launching or messaging a Subagent, end your turn. Its next message
resumes you; that message is the only signal to act on, so leave its session
status and any message queue unread.

A host can hold a Subagent on an approval only the user can give; when the user
reports a stall, the extension says how to surface it. A launch that fails
leaves what the host created; the extension says what that is and how to
inspect or close it. Close the Subagent's session with the extension's close
command once you have accepted the report. If a TASK COMPLETE never arrives,
the Paseo extension's `pending` command lists idle Subagents with delivery
state; the other hosts report synchronously and need no backstop.

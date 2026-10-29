---
name: subagents
description: Launch a Subagent for one Stage of a Work Item in its own session, exchange messages with it, and close it. Use when the Manager delegates a Stage.
---

The `manager` skill decides when to delegate and what a brief carries.
`scripts/subagent.py` prepares one Stage and prints its JSON launch spec;
a host extension starts the session from it.

**Before preparation**, read [`extensions.md`](extensions.md) and the chosen
host file. Choose for the Manager's conversation, not the shell executing the
command; follow the host's remote instructions when the machines differ.

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

The host file gives launch and close commands; `--extension` also accepts a
per-session file. `--manager` is your native address on the Manager's host,
used for launch validation. Prepare on the Stage's machine so `--cwd`, skills,
report path and extension are readable.

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

Each Subagent writes `.agents/reports/<item>-<stage>[-<axis>].md` in the main
checkout and sends a one-line TASK COMPLETE pointing at it in the same turn.
The spec's report path wins over the brief. Keep `--item` free of the Stage
name (`batch`, not `batch-review`). A report without a successful send leaves
the Stage open. For recado, exit 0 means stored; do not poll.

Preparation excludes `.agents/ledger.md` and `.agents/reports/` from git and
finds even untracked main-checkout project skills. To work in a worktree,
create it first and pass its path as `--cwd`.

## Messages

Every message starts with the Subagent's tag,
`[subagent-<stage>-<pid> · <item> · <stage>[ <axis>]]`, so you always know
which Work Item, Stage, and axis it is about. Preparation fills the tag into
the prompt; the spec's `tag` holds it. Every host uses recado. The prompt
supplies exact send/ask commands with address, tag and report metadata. The
launcher sets `RECADO_ADDR` to the spec `name`. Reply to a Question with
`recado reply ID "ANSWER"`; send a follow-up with `recado send NAME "MESSAGE"`
(or `recado send recado://MACHINE/NAME "MESSAGE"` for a remote Stage).

For remote Stages pass `--manager-recado` with the Manager's upstream address;
see [Rex remote](extensions/rex-remote.md) or
[Paseo remote](extensions/paseo-remote.md). Preparation uses that address rather
than remote `whoami`.

If recado lacks `send` or `ask`, preparation (including `--dry-run`) uses `recado update`
when available. With no executable or an older one without `update`, it
bootstraps with `go install` and `recado skill setup`. `RECADO_INSTALL_CMD`
overrides either installer. Preparation fails if installation fails or recado
cannot identify the Manager. Restart an already running Manager if newly
installed harness shims cannot identify it.

Messages are:

- `[…] TASK COMPLETE: <summary>`: the Stage is done; the report file holds
  the detail.
- `[…] QUESTION: <question>`: it waits for your answer.

Any tagged message asking for a choice is a question. Answer or send a
follow-up over recado; a follow-up earns a fresh TASK COMPLETE.

## Waiting

After launching or messaging a Subagent, end your turn. Its next message
resumes you; that message is the only signal to act on, so leave its session
status and any message queue unread.

A host can hold a Subagent on an approval only the user can give; when the user
reports a stall, the extension says how to surface it. A launch that fails
leaves what the host created; the extension says what that is and how to
inspect or close it. Close the Subagent's session with the extension's close
command once you have accepted the report.

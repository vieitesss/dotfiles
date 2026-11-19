# One bash launcher, Rex only, local only, no extensions, no Jev

Subagents run in local Rex windows. One bash script,
`agents/skills/subagents/scripts/subagent`, launches them. It has three
commands: `stages` prints each Stage with its skills and model profile;
`launch --stage S [--axis A] --item I [--cwd DIR] [--model ROLE]` reads the
brief on stdin, builds the prompt, opens a Rex window, and prints the
Subagent's name, window, block, and report path as JSON; `close WINDOW` closes
it. The Stage table in the script fixes each Stage's skills and model profile.
A model profile is one model with one thinking effort, named by role: builder,
writer, or critic. Nothing picks an effort at launch. `--model ROLE` swaps the
role, not the model.

Rex is the only host the Manager uses, so the host extensions, the selection
index, remote launch, the Claude Code engine, and Jev's effort picking are
gone. recado still carries every message between the Manager and its
Subagents, as [ADR 0004](0004-host-extensions-are-markdown.md) decided. The
launcher was about 1,800 lines of Python and tests. It is now one small bash
script with four behaviour tests in `tests/subagent.test.sh`.

This supersedes [ADR 0004](0004-host-extensions-are-markdown.md) and
[ADR 0005](0005-rex-is-the-only-host.md). [ADR 0003](0003-subagent-is-a-stage-instance.md)
keeps its routing rule; its update note says how launching now works.

## Considered options

- **Keep host extensions and remote launch.** Rejected: the extension files,
  the selection index, and two remote variants served no host in use. They
  should come back with a second host, not before.
- **Keep Jev picking the effort.** Rejected: a per-launch judgment added a
  second source of truth beside the Stage table. One fixed effort per role is
  enough, and it can be read in the table.

## Consequences

- A remote Stage, another terminal, or another host needs a new ADR.
- A Stage's model profile lives in the script's table. `update-subagents`
  reads the same table, so changing a model means editing one place.
- Offline tests use stub `rex` and `recado` on `PATH`. They cover the prompt,
  the missing-skill check, the model and effort passed to `pi`, and a Subagent
  that dies at startup.

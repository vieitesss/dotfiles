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

> Update (2026-11-21): a model role whose value starts with `agy/` launches
> `agy --model <model> --effort <effort> --mode auto -i <prompt>` in the Rex
> window; every other `<provider>/<model>` entry still launches `pi`. `recado`
> supports `agy` natively via `~/.gemini/config/hooks.json` and
> `agentapi send-message`, so Manager and Subagents communicate over `recado`
> regardless of harness.

> Update (2026-11-21): `--model` now also accepts a `<provider>/<model>` id
> (e.g. `agy/gemini-4-neon-high`) in addition to a role (`builder`, `writer`,
> `critic`), and the read-only `retro` Stage was added to the Stage table for
> session retrospectives.

> Update (2026-11-21): Harness selection moved out of the model string into an
> explicit `--harness` flag (`pi`, `agy`, `claude`, `opencode`), `--effort`
> overrides the thinking effort (`off|minimal|low|medium|high|xhigh|max`), and
> `load_profile` stores `(harness, model, effort)` per role. `--stage` is now
> optional so callers outside `/manager` can launch ad-hoc Subagents on any
> supported harness, model, and effort without injecting Stage skills.

> Update (2026-11-22): The Stage table now loads `tdd coding principles` for
> Build, `zero-tech-debt principles` for Refine, `research why` for Research,
> `writing-for-agents unslop` for Write, and `interrogate` for Review's `break`
> axis (other Review axes keep `review`). Model profiles are unchanged except
> the writer profile now uses `medium` effort.

# Subagent session extensions

A session host is an extension: an ordinary Markdown file that agents read and
follow. The Manager reads it to launch, answer and close a Subagent; the
Subagent reads it to reach the Manager. Nothing parses or executes it, and no
registry lists it.

## Picking one

Take the first row that matches the session you run in, and pass the file's
absolute path (`$SKILL/extensions/<host>.md`, `SKILL=~/.agents/skills/subagents`)
as `--extension`:

| Host  | Extension                       | Pick it when                                     |
| ----- | ------------------------------- | ------------------------------------------------ |
| Paseo | [paseo.md](extensions/paseo.md) | `PASEO_AGENT_ID` is set: you are a Paseo agent   |
| herdr | [herdr.md](extensions/herdr.md) | `HERDR_ENV` is set                               |
| tmux  | [tmux.md](extensions/tmux.md)   | `TMUX` is set                                    |

A Paseo agent can also sit inside a herdr or tmux pane; the Paseo row wins
there, and herdr wins over tmux. The user's explicit choice of host overrides
the order.

## Division of labour

[`SKILL.md`](SKILL.md) owns preparation: `scripts/subagent.py` validates the
Stage and prints a launch spec whose `prompt` already carries the Stage role,
skills, report path and how to reach the Manager. It runs the same on every
host, and `--dry-run` previews the spec.

The extension owns the session: launching, addressing, follow-up, closing and
what the Subagent runs to report. It leaves Stage, skills, model and effort
to the spec. Launch mechanics two hosts share live in one extension-owned
module both import (`extensions/host_launch.py` for tmux and herdr), never in
core: core prepares a host-independent spec.

## Writing one

Write a Markdown file that says, for its host:

1. how the Manager launches a session from the spec (the `prompt` is the first
   message; `cwd` is where it works);
2. which ids to keep and how to send a follow-up and close;
3. the commands the Subagent runs to send its Question or Completion report to
   the Manager's address; after a Question it ends its turn and the answer
   arrives as its next prompt.

Then pass its path as `--extension`. A file outside this directory works the
same way, and `scripts/subagent.py` stays unchanged. For an imaginary host
`acme`, the file can be this short:

```markdown
# Acme extension

Launch: `acme start --dir CWD --title NAME --prompt-file SPEC_PROMPT`; keep the
printed session id.
Follow-up: `acme say SESSION "MESSAGE"`. Close: `acme stop SESSION`.

Subagent: report with `acme say MANAGER "[TAG] TASK COMPLETE: <one line>; report: <path>"`
or `"[TAG] QUESTION: <question>"`, then end your turn.
```

A helper script beside the file (see `extensions/paseo/host.py`) is optional:
add one when launch mechanics are worth sharing, reading the spec on stdin.

Two rules: the default target is the Manager's own session or workspace, never
whichever one is focused; and the host file keeps the Manager's environment
and secrets out of the spec, the report and command arguments.

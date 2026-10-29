# Subagent session extensions

A session host is an extension: an ordinary Markdown file that agents read and
follow. The Manager reads it to launch and close a Subagent. Preparation gives
the Subagent exact recado reporting commands. Nothing parses or executes the
file, and no registry lists it.

## Picking one

Choose for the **Manager's conversation**. Its known host or the user's
explicit choice takes precedence. When commands run on the Manager's own
machine, take the first matching row below. Pass the file's absolute path on
the Subagent's machine (`$SKILL/extensions/<host>.md`,
`SKILL=~/.agents/skills/subagents`) as `--extension`:

| Host  | Extension                       | Pick it when                                     |
| ----- | ------------------------------- | ------------------------------------------------ |
| Paseo | [paseo.md](extensions/paseo.md) | `PASEO_AGENT_ID` is set: you are a Paseo agent   |
| herdr | [herdr.md](extensions/herdr.md) | `HERDR_ENV` is set                               |
| tmux  | [tmux.md](extensions/tmux.md)   | `TMUX` is set                                    |
| Rex   | [rex.md](extensions/rex.md)     | `REX_SESSION` is set                             |

A Paseo agent can also sit inside a herdr, tmux or Rex pane; the Paseo row
wins there, herdr wins over tmux, and either wins over the Rex terminal it
runs in.

On a remote execution machine, those variables describe that machine, not
the Manager. A Paseo Manager on a Mac remains a Paseo Manager when commands
run over SSH on an RPi, even without `PASEO_AGENT_ID` or `PASEO_CLI` there.
Keep the Manager's native address and use
[Paseo remote](extensions/paseo-remote.md) for a cross-machine recado route.
A Rex Manager whose Stage runs on a machine without Rex uses
[rex-remote.md](extensions/rex-remote.md): tmux there, recado machines for messages.
If the Manager's host, address or return route is unknown, ask in the current
conversation before preparing or launching.

## Shared launch safety

The extension owns its session. For tmux and Rex, the child
sources a 0600 temporary file containing only the allowlisted `TYPESAFE_API_KEY`
when set, deletes it, and receives its prompt through a separate temporary file.

Interactive Claude Code launches (herdr, tmux, Rex) allow only the prepared
recado send/ask commands and the report file without approval. They do not use `--mode auto` or bypass permissions. The
helper pre-accepts workspace trust only for the prepared directory in
`~/.claude.json`; other tool calls retain Claude's permission checks. Shared
mechanics live in `extensions/host_launch.py`, not core.

## Writing one

Write a Markdown file that says, for its host:

1. how the Manager launches a session from the spec (the `prompt` is the first
   message; `cwd` is where it works);
2. which ids to keep and how to close the session.

Then pass its path as `--extension`. A file outside this directory works the
same way, and `scripts/subagent.py` stays unchanged. For an imaginary host
`acme`, the file can be this short:

```markdown
# Acme extension

Launch: `acme start --dir CWD --title NAME --prompt-file SPEC_PROMPT`; keep the
printed session id.
Close: `acme stop SESSION`.
```

A helper script beside the file (see `extensions/paseo/host.py`) is optional:
add one when launch mechanics are worth sharing, reading the spec on stdin.

Two rules: the default target is the Manager's own session or workspace, never
whichever one is focused; and the host file keeps the Manager's environment
and secrets out of the spec, the report and command arguments.

# Rex is the only session host

Subagents run in Rex windows. A local Stage gets a background window in the
Manager's Rex session. A remote Stage runs on another Rex host: the Manager
prepares and launches it over SSH on that host, whose own Rex server owns the
window, and then reaches the window with `rex -S HOST` to capture or close it.
recado carries every message in both directions. The Paseo, herdr, tmux, and
rex-remote extensions, their helpers, and the index that chose between them
are gone.

## Considered options

- **Keep one extension per host.** It covers every terminal the Manager might
  run in, but four launchers and two remote variants had to agree on ids,
  trust, and messaging. Most of the skill prose went to choosing between them.
- **Drive remote Subagents with `rex -S HOST send`.** It needs no recado on the
  remote host, but it types keystrokes into whatever the terminal shows. It
  can corrupt a prompt the user is typing there, and it cannot tell a
  delivered message from a lost one. recado delivers a message as a harness
  turn, not as keystrokes.
- **Launch remote windows from the Manager's machine with `rex -S HOST window
  new`.** That is one hop fewer, but the prompt and env temp files and the
  prepared paths must exist on the Stage's machine. Preparing over SSH keeps
  them there.

## Consequences

- A remote host needs Rex, recado and its harness hooks, the dotfiles skills
  at `~/.agents/skills`, and SSH access through the recado machine of the same
  name.
- The Manager must run in a Rex terminal; `--manager` is its `REX_BLOCK`.
- The extension still sends a kickoff after a remote launch, because recado
  opens the return route only when the Manager first sends to the machine.
- `--extension` still accepts any Markdown file, so
  [ADR 0004](0004-host-extensions-are-markdown.md) holds for how a host is
  described. Its selection order and pointer index are superseded.

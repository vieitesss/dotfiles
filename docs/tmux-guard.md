# Tmux guard and sandbox

Agents have killed the live tmux server by running unqualified destructive
commands after inheriting `TMUX` (2026-10-05 retrospective). This page covers
the two mechanisms that make that deterministic: a private test server
(`scripts/tmux-sandbox`) and a tool-level guard (`scripts/tmux-guard`).

## Run tmux tests safely

```sh
just test-tmux                 # all tmux guard + sandbox tests
tmux-sandbox run -- CMD ...    # run a command with a private tmux server
tmux-sandbox new               # print a state dir; socket is <dir>/run/tmux.sock
tmux-sandbox cleanup --state DIR
```

Inside `tmux-sandbox run`, `TMUX` and `TMUX_PANE` are unset, `HOME` and
`TMUX_TMPDIR` point at the state dir, and a `tmux` shim first on `PATH` routes
every nested bare `tmux` call to the owned socket. The shim refuses `-S`/`-L`,
so a nested command cannot fall back to the live/default socket. Cleanup kills
only the verified owned socket and refuses any path that is not an owned state
directory.

## What the guard blocks

For agent-issued shell tool calls, `scripts/tmux-guard` returns `ask` for a
destructive operation unless it explicitly targets an owned sandbox socket with
`-S <state>/run/tmux.sock`:

| Blocked | Notes |
|---|---|
| `kill-server`, `kill-session`, `kill-client` | any form, including targeted `-t` |
| `kill-window -a`, `kill-pane -a` | targeted `kill-window -t`/`kill-pane` stay allowed |
| `detach-client -a`, `detach-client -P` | plain `detach-client` stays allowed |
| `source-file` (alias `source`) | config reload; allowed on an owned socket |
| `pkill`/`killall` matching tmux, `kill $(pgrep tmux)` | no socket to prove |
| `run-shell`/`if-shell`/`bind-key`/`confirm-before` carrying a guarded command | |
| chains, wrappers (`sudo`, `env`, `sh -c`, `eval`, `xargs`), substitutions, `alias` bodies | conservative `ask` |
| unparsable command with destructive tmux evidence | fail closed |
| unknown wrapper containing an unexplained `tmux` + guarded word | fail closed |

Ordinary navigation (`ls`, `split-window`, `select-pane`, `send-keys`,
`capture-pane`, `show-options`, `set-option -w`, ...) and the targeted
`kill-window -t` used by `subagent.py --close` stay allowed.

## Approval

`ask` is a request for a real harness-human approval -- Pi shows
`ctx.ui.confirm`, Claude Code shows its permission prompt. There is no env
variable, flag, or token that grants approval. With no UI to prompt (Pi
non-interactive, Claude headless/`bypassPermissions`/`dontAsk`), the call is
blocked/denied. The Claude adapter exits `2` on any internal error; `exit 1`
would fail open and is never used.

## Activation

- **Pi:** `pi/agent/extensions/tmux-guard/` is inside the already-managed
  `~/.pi/agent/extensions` directory, so it loads automatically. It resolves
  the guard from its own checkout first, then `~/.local/bin/tmux-guard`; if
  neither exists it blocks guarded commands rather than passing them.
- **Claude, launcher-spawned:** `subagent.py` passes `--settings <inline JSON>`
  pointing at the checkout's `scripts/claude-tmux-guard`, so both tmux- and
  herdr-launched Subagents are guarded without touching user settings. When the
  checkout has no guard, the launcher refuses to start the session instead of
  warning and continuing.
- **Claude, direct sessions:** run `claude-guarded` instead of `claude`. It is
  an explicitly named command (not a `claude` alias) that adds
  `claude/tmux-guard.settings.json` and exports `CLAUDE_TMUX_GUARD` for the
  current checkout. To opt in without the wrapper, link the fragment
  (`./install.sh claude` creates `~/.claude/dotfiles-tmux-guard.json`) and run
  `claude --settings ~/.claude/dotfiles-tmux-guard.json`. `~/.claude/settings.json`
  is never modified. Both hook wrappers run the adapter and translate *any*
  non-zero status (1, 126, 127, killed, ...) into exit 2, because Claude Code
  only blocks on exit 2; the adapter's `ask`/`deny` JSON is passed through only
  when it exits 0. A missing, non-executable, or broken guard therefore blocks
  Bash calls instead of silently allowing them.
- **Manifests:** both `MAC.manifest` and `LINUX.manifest` install
  `tmux-guard`, `claude-tmux-guard`, `claude-guarded`, `tmux-sandbox`, and the
  Claude settings fragment. Nothing needs to be installed for the tests or the
  current checkout to be guarded.

## Limits (not a sandbox)

- It guards harness tool calls only. Human shells, `!` commands, other
  extensions' own `pi.exec`, MCP servers, subprocesses inside a tool, other
  harnesses, and remote (`ssh`/`docker exec`) commands are outside it.
- String analysis is a deterministic speed bump: variable indirection
  (`$CMD`), tmux `command-alias`, `eval` inside data, base64/`printf`
  obfuscation, and process renaming can evade it. When the guard cannot prove
  the target it asks instead of allowing. Nested shell arguments (`run-shell`,
  `if-shell` conditions, `detach-client -E`) are judged on their own terms: an
  owned outer socket never authorizes a nested command that names the live or
  an unrelated socket. tmux command lists (`if-shell`'s second argument,
  `bind-key`/`confirm-before` bodies) do run against the outer server, so an
  owned outer `-S` authorizes them.
- Ownership is a marker check (`state.json` + uid + mode 0700 + exact socket
  path under `TMPDIR`), not cryptography; it separates the runner's own
  private socket from unrelated private sockets, nothing more.
- The guard and adapters are repo files the agent can edit. OS user isolation
  or a container is the only real boundary.

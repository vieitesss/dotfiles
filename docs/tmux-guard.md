# Tmux guard and test sandbox

An agent inherited `TMUX`, ran an unqualified `tmux kill-server`, and killed the
live server (2026-10-05 retrospective). Two small pieces reduce that risk. The
guard is a **best-effort semantic speed bump, not a safety boundary.**

## Test sandbox

`tmux-sandbox -- CMD [ARGS...]` runs one command against its own private server
(`just test-tmux` runs the tests). It creates a unique state directory under the
real `TMPDIR` with its own socket, points `HOME`/`TMUX_TMPDIR` at it, unsets the
inherited `TMUX`/`TMUX_PANE`, and puts a `tmux` shim first on `PATH` so every
nested bare `tmux` call reaches only that socket; on exit that server is killed
and the state removed. There is no other mode: cleanup never accepts a
caller-supplied path, so no server outside the process can be aimed at.

The shim refuses **any leading global option** (`-S`, `-2S`, `-L`, `-f`, ...)
with exit 87 rather than reimplementing tmux's `getopt`, so a clustered socket
selector cannot slip through; subcommand flags such as `capture-pane -S -5` stay
legal, and the private server is always started with an explicit empty config
(`-f /dev/null`), which replaces tmux's whole default config list (system config,
`~/.tmux.conf`, `$XDG_CONFIG_HOME/tmux/tmux.conf`), so an inherited
`XDG_CONFIG_HOME` cannot run caller configuration. The harmless fixture config is
still loaded explicitly with `source-file`. An absolute path to the real tmux
binary still bypasses it: a test convenience, not a sandbox against a hostile
agent.

## Guard

`tmux-guard [--cwd DIR] -- COMMAND` prints one line, `allow` or
`ask<TAB>reason`; `--claude-hook` reads a Claude PreToolUse payload on stdin, and
`--claude-settings` prints the JSON for `claude --settings`. One executable owns
all three. Commands without `tmux` in their text make no call and always run.
Everything else goes to one Jev `noul` question -- does running it require human
approval under this policy? -- with `state` = the command text, cwd, and live
tmux socket path. The criteria name the destructive operations and make explicit
non-live sockets and the repository's own test tooling (`just test-tmux`,
`tmux-sandbox`) the false side. `noul >= 0.35` -> `ask`, below -> `allow`; `ask`
is a real human decision (Pi confirm dialog, Claude permission prompt) and no env
var, flag, or token grants approval.

Failures never allow: a missing key, HTTP error, bad JSON, or an
unusable/NaN/out-of-range answer all ask, and so does a screen that outlives a 5s
total wall-clock deadline (POSIX `SIGALRM`/`setitimer` around the request, plus
urllib's 3s per-read inactivity timeout; the deadline needs a Unix main thread,
and where that does not hold screening asks); with no UI (Pi headless, Claude
headless/`bypassPermissions`/`dontAsk`) ask becomes a block; the Claude hook exits
2 on any internal error, because exit 1 would fail open. Screened commands POST
the command string, cwd, and live socket path to
`https://api.typesafe.ai/v1/systemone` (`Bearer $TYPESAFE_API_KEY`, model
`jev-latest`) -- shell commands can contain sensitive literals -- and nothing
else from the environment is sent; typical latency ~0.3s, Python 3 stdlib only.

Activation: the Pi extension in the managed `~/.pi/agent/extensions` resolves this
checkout's `scripts/tmux-guard`, then `~/.local/bin/tmux-guard`; the Subagent
launcher and the opt-in `claude-guarded` both use `tmux-guard --claude-settings`
(a missing guard refuses to start; `TYPESAFE_API_KEY` already reaches children via
`PASSTHROUGH_ENV`) and neither edits `~/.claude/settings.json`. Both manifests
install `tmux-guard`, `claude-guarded`, and `tmux-sandbox`.

Limits: hidden tmux calls (opaque scripts, dynamic names, aliases defined
elsewhere, a program running tmux itself) are outside the prefilter; the model can
be wrong either way; only harness tool calls are covered, not human shells, other
harnesses, MCP servers, or `pi.exec`; the guard can be edited, and OS user
isolation is the only real boundary. `run-shell`/`if-shell` bodies run real
processes. `just test-tmux` is hermetic (HTTP stubbed, no key, private sockets
with a `TMUX` sentinel that must survive untouched); for a live judgment:
`TYPESAFE_API_KEY=... scripts/tmux-guard 'tmux kill-server'`.

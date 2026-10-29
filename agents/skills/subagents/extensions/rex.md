# Rex extension

Pick this file when `REX_SESSION` is set and no Paseo, herdr or tmux extension
applies: the Subagent gets a background window in your Rex session. Pass its
absolute path as `--extension`.

A herdr or tmux running inside a Rex block wins over this file: it is the inner
multiplexer, and text typed into that block would go to its active pane.

For a Stage on another machine without Rex, such as an RPi, use
[rex-remote.md](rex-remote.md) instead.

## Manager: launching a Stage

Prepare the Stage as in [`SKILL.md`](../SKILL.md) with
`--extension "$SKILL/extensions/rex.md" --manager "$REX_BLOCK"`, then start
the session from the spec:

```bash
printf '%s\n' "$spec" | python3 "$SKILL/extensions/rex/host.py" launch [SESSION]
```

`launch` prints
`{"host":"rex","session":"session:...","window":"window:...","block":"block:...",...}`.
Keep the window id to close and the spec name for messaging; record both in
the Ledger.

- The default session is the calling block's, from `REX_SESSION`, not
  whichever one the app shows. Pass a session label or id as `SESSION` to
  override. `REX_SERVER`, when set, selects the server as it does for every
  `rex` command.
- The helper finds `rex` on `PATH`, else in `REX_BIN_DIR`, which Rex sets in
  its terminals; outside one, put the app's `rex` on `PATH`.
- The window opens without focus and with `--keep-open`, so the agent's last
  screen stays readable after it exits. It runs a login shell; multi-line
  briefs arrive whole.
- `launch` refuses (exit 2) when `--manager` is not the block it runs in, or
  when `PASEO_AGENT_ID` is set: a Paseo agent has no block of its own. Use
  the Paseo extension instead.
- A failed launch exits 2, prints the block's last lines, and leaves the
  window open, with its ids on stderr, for diagnosis. Close that window before
  relaunching.

For a session of its own in a project or worktree, create it and pass its id
as `SESSION`:

```bash
rex new LABEL -c DIR --json    # -> .session_id is the session
```

Create a fresh worktree with `git worktree add -b BRANCH <repo-parent>/<repo>-wt/<name>`
from an up-to-date main (nexo has no Rex backend), then pass the worktree path
as `--cwd` and, optionally, a `rex new` session rooted there as `SESSION`.

## Manager: close

Once the report is accepted:

```bash
python3 "$SKILL/extensions/rex/host.py" close WINDOW
```

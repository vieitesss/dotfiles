# tmux extension

Pick this file when `TMUX` is set and no Paseo or herdr extension applies: the
Subagent gets a window in your tmux session. Pass its absolute path as
`--extension`.

## Manager: launching a Stage

Prepare the Stage as in [`SKILL.md`](../SKILL.md) with
`--extension "$SKILL/extensions/tmux.md" --manager "$TMUX_PANE"`, then start
the session from the spec:

```bash
printf '%s\n' "$spec" | python3 "$SKILL/extensions/tmux/host.py" launch [SESSION]
```

`launch` prints `{"host":"tmux","session":"...","window":"@N","pane":"%N",...}`.
Keep the window id to close and the spec name for messaging; record both in
the Ledger.

- The default session is the calling pane's, from `TMUX_PANE`, not whichever
  session is attached. Pass a session name or id as `SESSION` to override.
- The Subagent runs a login shell; multi-line briefs arrive whole.
- `launch` refuses (exit 2) when `--manager` is not the pane it runs in, or
  when `PASEO_AGENT_ID` is set: a Paseo agent has no pane of its own and only
  inherits one. Use the Paseo extension instead.
- A failed launch exits 2 and leaves the window open, with its ids on stderr,
  for diagnosis. Close that window before relaunching.

For a session of its own in a project or worktree, create it without focus and
pass its id as `SESSION`:

```bash
nexo --json --backend tmux open --no-focus DIR    # -> .id is the session
```

Create a fresh worktree with:

```bash
nexo --json worktree create --no-focus --new-branch --add-parent \
  REPO BRANCH <repo-parent>/<repo>-wt/<name>
```

The branch starts from REPO's current HEAD, so update main first. The command
opens the worktree without focus; pass its `.container.id` as `SESSION` and the
worktree path as `--cwd`. `--add-parent` adds the `-wt` folder to nexo's
paths, so `open` then works for every worktree in it.

## Manager: close

Once the report is accepted:

```bash
python3 "$SKILL/extensions/tmux/host.py" close WINDOW
```

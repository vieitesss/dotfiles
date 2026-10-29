# herdr extension

Pick this file when `HERDR_ENV` is set and you are not a Paseo agent: the
Subagent gets a tab in your herdr workspace. Pass its absolute path as
`--extension`.

## Manager: launching a Stage

Prepare the Stage as in [`SKILL.md`](../SKILL.md) with
`--extension "$SKILL/extensions/herdr.md" --manager "$HERDR_PANE_ID"`, then
start the session from the spec:

```bash
printf '%s\n' "$spec" | python3 "$SKILL/extensions/herdr/host.py" launch [WORKSPACE] [TIMEOUT_MS]
```

`launch` prints `{"host":"herdr","workspace":"...","tab":"...","pane":"...","name":"subagent-..."}`.
Keep the tab id to close and the `name` to address the Subagent; record both in
the Ledger.

- The default workspace is the calling agent's, from `HERDR_WORKSPACE_ID`, not
  whichever workspace is focused. The helper stops when that variable is
  unset. Pass a workspace id as `WORKSPACE` to override, and a start timeout in
  ms as `TIMEOUT_MS`.
- The tab opens without focus, the agent starts in its root pane, and the
  brief is submitted as one prompt, so multi-line text arrives whole. A busy
  pane is retried for up to 30s.
- `launch` refuses, exiting 2, when you are a Paseo agent or `--manager` is
  not the pane you run in: a Paseo agent inherits the herdr variables of
  whatever pane started its daemon.
- A failed launch exits 2 and leaves the tab open, with its ids on stderr, for
  diagnosis. Close that tab before relaunching.

For a workspace of its own on a project or worktree, create it without focus
and pass its id as `WORKSPACE`:

```bash
nexo --json --backend herdr open --no-focus DIR   # -> .id is the workspace
```

Create a fresh worktree as in [`tmux.md`](tmux.md); pass its `.container.id` as
`WORKSPACE` and the worktree path as `--cwd`.

## Manager: close

Once the report is accepted:

```bash
python3 "$SKILL/extensions/herdr/host.py" close TAB
```

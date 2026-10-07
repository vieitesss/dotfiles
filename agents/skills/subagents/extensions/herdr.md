# herdr extension

Pick this file when `HERDR_ENV` is set and you are not a Paseo agent: the
Subagent gets a tab in your herdr workspace. Pass its absolute path as
`--extension`; the Subagent is told to read it to report.

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
- A failed launch exits 2 and leaves the tab open, with its ids on stderr, for
  diagnosis. Close that tab before relaunching.
- A Claude Code role (`engine.kind` `claude`) also gets a narrow
  `--allowedTools` list: `Bash(herdr agent prompt *)` (the report path to the
  Manager) and `Edit(//<report path>)` for the report file (Claude Code's
  absolute-path form). These allowlisted reporting commands and report edits
  run without approval; other tool calls remain subject to Claude Code's
  permission checks. There is no broad bypass, and herdr launches get no
  `--mode auto`. Because interactive `claude` cannot skip its workspace-trust dialog,
  the helper also pre-accepts that dialog for the prepared directory by setting
  `projects[<cwd>].hasTrustDialogAccepted` in `~/.claude.json` before launch.
  Only that directory is marked trusted.

For a workspace of its own on a project or worktree, create it without focus
and pass its id as `WORKSPACE`:

```bash
nexo --json --backend herdr open --no-focus DIR   # -> .id is the workspace
```

Create a fresh worktree as in [`tmux.md`](tmux.md); pass its `.container.id` as
`WORKSPACE` and the worktree path as `--cwd`.

## Manager: follow-up and close

```bash
python3 "$SKILL/extensions/herdr/host.py" notify SUBAGENT_NAME "MESSAGE"
python3 "$SKILL/extensions/herdr/host.py" close TAB
```

`notify` runs `herdr agent prompt`, so you can also call that directly. If
herdr rejects a prompt (for example `agent_blocked`), wait a few seconds and
retry. Close the tab once the report is accepted.

## Subagent: reporting

Prompt the Manager's agent by the address in your prompt. A herdr agent command
accepts either the pane id hosting the agent or a unique live agent name, so
the Manager's `$HERDR_PANE_ID` is a valid address:

```bash
herdr agent prompt MANAGER "[TAG] TASK COMPLETE: <one line>; report: <report path>"
herdr agent prompt MANAGER "[TAG] QUESTION: <question>"
```

After a QUESTION, end your turn; the Manager's answer arrives as your next
prompt. Do not use intercom, do not poll, and do not read other panes.

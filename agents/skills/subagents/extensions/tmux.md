# tmux extension

Pick this file when `TMUX` is set and no Paseo or herdr extension applies: the
Subagent gets a window in your tmux session. Pass its absolute path as
`--extension`; the Subagent is told to read it to report.

## Manager: launching a Stage

Prepare the Stage as in [`SKILL.md`](../SKILL.md) with
`--extension "$SKILL/extensions/tmux.md" --manager "$TMUX_PANE"`, then start
the session from the spec:

```bash
printf '%s\n' "$spec" | python3 "$SKILL/extensions/tmux/host.py" launch [SESSION]
```

`launch` prints `{"host":"tmux","session":"...","window":"@N","pane":"%N",...}`.
Keep the window id to close and the pane id to address the Subagent; record
both in the Ledger.

- The default session is the calling pane's, from `TMUX_PANE`, not whichever
  session is attached. Pass a session name or id as `SESSION` to override.
- The Subagent runs a login shell, sources a 0600 file holding only the
  allowlisted secret (`TYPESAFE_API_KEY`, when set), deletes it, then starts
  the engine. The prompt travels through a temp file, so multi-line briefs
  arrive whole.
- A failed launch exits 2 and leaves the window open, with its ids on stderr,
  for diagnosis. Close that window before relaunching.
- A Claude Code role (`engine.kind` `claude`) also gets a narrow
  `--allowedTools` list: `Bash(python3 <this helper> notify *)`, the same rule
  for the interpreter running the helper, and `Edit(//<report path>)` for the
  report file (Claude Code's absolute-path form). These allowlisted reporting
  commands and report edits run without approval; other tool calls remain
  subject to Claude Code's permission checks. There is no broad bypass, and
  tmux launches get no `--mode auto`. Because interactive `claude` cannot skip its
  workspace-trust dialog, the helper also pre-accepts that dialog for the
  prepared directory by setting `projects[<cwd>].hasTrustDialogAccepted` in
  `~/.claude.json` before launch. Only that directory is marked trusted.

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

## Manager: follow-up and close

```bash
python3 "$SKILL/extensions/tmux/host.py" notify SUBAGENT_PANE "MESSAGE"
python3 "$SKILL/extensions/tmux/host.py" close WINDOW
```

`notify` pastes the message and presses Enter, so a multi-line follow-up
arrives as one prompt. Close the window once the report is accepted.

## Subagent: reporting

Type into the Manager's pane, named in your prompt, through the helper next to
this file (`tmux/host.py` in the directory that holds it):

```bash
python3 EXTENSIONS_DIR/tmux/host.py notify MANAGER "[TAG] TASK COMPLETE: <one line>; report: <report path>"
python3 EXTENSIONS_DIR/tmux/host.py notify MANAGER "[TAG] QUESTION: <question>"
```

After a QUESTION, end your turn; the Manager's answer arrives as your next
prompt. Do not use intercom, do not poll, and do not read other panes.

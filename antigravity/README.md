# Antigravity CLI (`agy`)

## Custom status line

`statusline.sh` mirrors the custom Pi footer defined in
`pi/agent/extensions/custom-footer.ts` and `claude/statusline.sh`. It reads the
status line JSON that Antigravity CLI writes to stdin and prints one line:

```text
<tokens> · <context %> · <cost>        <cwd> · <branch>        <model> · <effort>
```

| Segment | Antigravity CLI field | Pi source |
|---|---|---|
| tokens | `context_window.total_input_tokens` (falls back to `current_usage.input_tokens`) | `ctx.getContextUsage().tokens` |
| context % | `context_window.used_percentage` | `ctx.getContextUsage().percent` |
| cost | `cost.total_usd` | sum of session usage cost |
| cwd | `workspace.current_dir` / `cwd` (`$HOME` -> `~`) | `ctx.cwd` |
| branch | `git branch --show-current` in the cwd | same |
| model | `model.id` (falls back to `model.display_name`, strips trailing `(Effort)`) | `model.id` |
| effort | `model.effort` (falls back to parenthetical effort in model name, else `off`) | active thinking level |

Colors follow the Gruber themes Pi uses (`gruber-lighter` / `gruber-darker`);
on macOS the script auto-detects the system appearance, elsewhere it defaults
to the light palette in `pi/agent/settings.json`. Set
`AGY_STATUS_THEME=light|dark` to force one.

### Install

The script is a managed config. Link it with the repository installer:

```sh
./install.sh antigravity
```

This creates `~/.gemini/antigravity-cli/statusline.sh -> <repo>/antigravity/statusline.sh`.
If `~/.gemini/antigravity-cli/statusline.sh` already exists the installer skips it.

Antigravity CLI's `settings.json` is intentionally not tracked here (it holds
machine-local settings). Enable the status line from inside `agy`:

```text
/statusline ~/.gemini/antigravity-cli/statusline.sh
```

Or add the `statusLine` block to `~/.gemini/antigravity-cli/settings.json` by hand:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.gemini/antigravity-cli/statusline.sh",
    "enabled": true,
    "padding": 0,
    "stack_with_default": false
  }
}
```

Requires `bash` and `jq`.

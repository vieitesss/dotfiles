# Claude Code

## Custom status line

`statusline.sh` mirrors the custom Pi footer defined in
`pi/agent/extensions/custom-footer.ts`. It reads the status line JSON that
Claude Code writes to stdin and prints one line:

```text
<tokens> · <context %> · <cost>        <cwd> · <branch>        <model> · <effort>
```

| Segment | Claude Code field | Pi source |
|---|---|---|
| tokens | `context_window.total_input_tokens` | `ctx.getContextUsage().tokens` |
| context % | `context_window.used_percentage` | `ctx.getContextUsage().percent` |
| cost | `cost.total_cost_usd` | sum of session usage cost |
| cwd | `workspace.current_dir` (`$HOME` -> `~`) | `ctx.cwd` |
| branch | `git branch --show-current` in the cwd | same |
| model | `model.id` (falls back to `model.display_name`) | `model.id` |
| effort | `effort.level`, else `thinking.enabled` -> `on`/`off` | active thinking level |

Colors follow the Gruber themes Pi uses (`gruber-lighter` / `gruber-darker`);
on macOS the script auto-detects the system appearance, elsewhere it defaults
to the light palette in `pi/agent/settings.json`. Set
`CLAUDE_STATUS_THEME=light|dark` to force one.

### Install

The script is a managed config. Link it with the repository installer:

```sh
./install.sh claude
```

This creates `~/.claude/statusline.sh -> <repo>/claude/statusline.sh`. If
`~/.claude/statusline.sh` already exists the installer skips it.

Claude Code's `settings.json` is intentionally not tracked here (it holds
machine-local settings). Add the `statusLine` block to
`~/.claude/settings.json` by hand after linking:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
```

Claude Code reloads settings automatically. Requires `bash` and `jq`.

# Theme rollback: Rosé Pine → Gruber

On 2026-09-15 the light/dark auto-switching theme pair for Ghostty, Herdr, and
Pi was switched back from Rosé Pine to Gruber. This note stores the previous
Rosé Pine configuration so it can be restored.

| Tool    | Previous light   | Previous dark | Current light                        | Current dark                         |
|---------|------------------|---------------|--------------------------------------|--------------------------------------|
| Ghostty | `Rose Pine Dawn` | `Rose Pine`   | `gruber-lighter`                     | `gruber-darker`                      |
| Herdr   | `rose-pine-dawn` | `rose-pine`   | `gruber-lighter` (custom overrides)  | `gruber-darker` (custom overrides)   |
| Pi      | `rosepine-dawn`  | `rosepine`    | `gruber-lighter`                     | `gruber-darker`                      |

Auto-switching (`light:`/`dark:` in Ghostty, `auto_switch = true` in Herdr, and
`scripts/system-appearance` for Pi) is unchanged.

## Ghostty

Previous line in `ghostty/config`:

```ini
theme = light:Rose Pine Dawn,dark:Rose Pine
```

Restore by putting the line above back into `ghostty/config`. The repo-owned
`ghostty/themes/gruber-*` files were left untouched.

## Herdr

Previous `[theme]` section of `herdr/config.toml`:

```toml
[theme]
# Built-in themes: catppuccin, terminal, tokyo-night, dracula, nord,
#                  gruvbox, one-dark, solarized, kanagawa, rose-pine,
#                  vesper
# name = "gruvbox"

# Follow host terminal light/dark appearance and switch Herdr UI themes.
auto_switch = true
dark_name = "rose-pine"
light_name = "rose-pine-dawn"
```

Restore by replacing the current `[theme]` section with the block above and
removing the `[theme.custom.dark]` / `[theme.custom.light]` Gruber override
tables; otherwise they would override the Rosé Pine base palette. Then run
`herdr server reload-config`.

## Pi

Previous `pi/agent/settings.json` value:

- `"theme": "rosepine-system"`
- package `npm:@inobit/pi-themes` is still present, kept for easy revert.

The previous Pi generation block in `scripts/system-appearance` was:

```sh
# Pi hot-reloads the active custom theme file. Build that stable file from the
# installed Rosé Pine package so running and future sessions use the same name.
pi_package="$HOME/.pi/agent/npm/node_modules/@inobit/pi-themes"
case "$mode" in
    light) pi_source="$pi_package/themes/rosepine-dawn.json" ;;
    dark) pi_source="$pi_package/themes/rosepine.json" ;;
esac
pi_theme_dir="$HOME/.pi/agent/themes"
pi_theme_file="$pi_theme_dir/rosepine-system.json"
if [ -f "$pi_source" ]; then
    mkdir -p "$pi_theme_dir"
    pi_tmp="$pi_theme_file.tmp.$$"
    sed 's/"name": "rosepine[^"]*"/"name": "rosepine-system"/' "$pi_source" > "$pi_tmp"
    mv "$pi_tmp" "$pi_theme_file"
else
    echo "WARN: Pi Rosé Pine theme package is not installed; skipped Pi" >&2
fi
```

`~/.pi/agent/themes/rosepine-system.json` still exists.
`gruber-system.json` is the file the script regenerates.

To fully revert Pi: set `"theme": "rosepine-system"`, restore the block above,
and reload.

## Wallpapers

Previous wallpapers in `scripts/system-appearance`:

- dark: `$HOME/Pictures/astronaut_rosepine.png`
- light: `$HOME/Pictures/astronaut_rosepinedawn.png`

Current:

- dark: `$HOME/Pictures/astronaut_umbraline.png`
- light: `$HOME/Pictures/astronaut_light.png`

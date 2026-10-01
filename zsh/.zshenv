
. "$HOME/.cargo/env"

# Non-interactive shells (e.g. `ssh host tmux new-session`) read only this file,
# so anything a tmux server started that way needs must be on PATH here.
[ -d "$HOME/.fzf/bin" ] && export PATH="$PATH:$HOME/.fzf/bin"
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# SSH commands get no locale, and tmux without UTF-8 mangles tabs in its -F
# output (nexo's remote listing parses it).
[ -z "$LANG$LC_ALL" ] && export LANG=en_US.UTF-8

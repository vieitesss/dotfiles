alias i := install
alias nvim := update_neovim

_default:
    just -l

install *args="":
    ./install.sh {{args}}

update_neovim *args="":
    ./scripts/update-nvim-nightly.sh {{args}}

# Isolated tmux servers, the destructive-command guard, and the Claude/Pi
# adapters. Safe to run inside a live tmux session; see docs/tmux-guard.md.
test-tmux:
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
    node --test pi/agent/extensions/tmux-guard/core.test.mjs

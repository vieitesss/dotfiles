alias i := install
alias nvim := update_neovim

_default:
    just -l

install *args="":
    ./install.sh {{args}}

check:
    ./scripts/check-shell.sh
    ./tests/install.test.sh
    ./tests/tmux-sandbox.test.sh
    ./tests/system-appearance.test.sh
    python3 -m unittest discover -s agents/skills/subagents/scripts
    ./tests/doctor.test.sh
    cd agents/skills/review-github-pr-comments/scripts && if [ -d node_modules ]; then npm test; else npm ci && npm test; fi

doctor:
    ./scripts/doctor

update_neovim *args="":
    ./scripts/update-nvim-nightly.sh {{args}}

alias i := install
alias nvim := update_neovim

_default:
    just -l

install *args="":
    ./install.sh {{args}}

update_neovim *args="":
    ./scripts/update-nvim-nightly.sh {{args}}

alias i := install

_default:
    just -l

install *args="":
    ./install.sh {{args}}

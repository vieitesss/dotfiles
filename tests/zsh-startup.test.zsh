#!/usr/bin/env zsh
# Exercise the deferred Oh My Zsh loaders without network or user config.
# Run: zsh -f tests/zsh-startup.test.zsh
set -eu

repo_root=${0:A:h:h}
typeset -a loaded_snippets=()

zinit() {
    case "$1" in
        ice) ;;
        snippet) loaded_snippets+=("$2") ;;
        *)
            print -u2 -- "FAIL: deferred Oh My Zsh loader used zinit $* instead of snippet"
            return 1
            ;;
    esac
}

for plugin in sudo command_not_found; do
    loader="_defer_${plugin}_plugin"
    definition=$(awk -v name="$loader" '
        $0 == name "() {" { copying = 1 }
        copying { print }
        copying && $0 == "}" { exit }
    ' "$repo_root/zsh/.zshrc")
    [[ -n "$definition" ]] || { print -u2 -- "FAIL: missing $loader"; exit 1; }
    eval "$definition"
    "$loader"
done

[[ "${(j: :)loaded_snippets}" == 'OMZP::sudo OMZP::command-not-found' ]] || {
    print -u2 -- 'FAIL: deferred Oh My Zsh plugins were not loaded as snippets'
    exit 1
}
print -- 'ok: deferred Oh My Zsh plugins load as snippets, not Git repositories'

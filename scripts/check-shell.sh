#!/usr/bin/env bash

# Lint every tracked shell script in the dialect it is written in:
#   bash -> bash -n + shellcheck
#   sh   -> sh -n + shellcheck -s sh
#   zsh  -> zsh -n
#
# zsh files are never parsed by ShellCheck; it cannot parse zsh. Files under
# zsh/ are zsh config sourced by .zshrc, so their location decides the dialect
# even when an editor-style bash shebang is left at the top.

set -uo pipefail

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
cd "$repo_root" || exit 1

failed=0
checked_bash=0
checked_sh=0
checked_zsh=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failed=1
}

require() {
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'FAIL: %s is required for just check but is not on PATH\n' "$tool" >&2
            exit 1
        fi
    done
}

lint_bash() { bash -n "$1" && shellcheck "$1"; }
lint_sh() { sh -n "$1" && shellcheck -s sh "$1"; }
lint_zsh() { zsh -n "$1"; }

require git

# git ls-files is the single source of truth for what to lint. A failed or
# empty listing must fail the check rather than lint nothing and pass.
if ! tracked=$(git ls-files); then
    printf 'FAIL: git ls-files failed; cannot enumerate tracked files\n' >&2
    exit 1
fi

while IFS= read -r file; do
    [ -f "$file" ] || continue

    case "$file" in
        zsh/*)
            dialect=zsh
            ;;
        *)
            shebang=
            IFS= read -r shebang < "$file" || true
            case "$shebang" in
                '#!'*)
                    case "$shebang" in
                        *zsh*) dialect=zsh ;;
                        *bash*) dialect=bash ;;
                        *'/sh'* | *' sh'*) dialect="sh" ;;
                        *) continue ;;
                    esac
                    ;;
                *) continue ;;
            esac
            ;;
    esac

    case "$dialect" in
        bash)
            require bash shellcheck
            checked_bash=$((checked_bash + 1))
            lint_bash "$file" || fail "$file (bash)"
            ;;
        sh)
            require sh shellcheck
            checked_sh=$((checked_sh + 1))
            lint_sh "$file" || fail "$file (sh)"
            ;;
        zsh)
            require zsh
            checked_zsh=$((checked_zsh + 1))
            lint_zsh "$file" || fail "$file (zsh)"
            ;;
    esac
done <<< "$tracked"

total=$((checked_bash + checked_sh + checked_zsh))

if [ "$total" -eq 0 ]; then
    printf 'FAIL: no shell scripts found; git ls-files returned nothing\n' >&2
    exit 1
fi

if [ "$failed" -ne 0 ]; then
    printf 'FAIL: shell lint failed\n' >&2
    exit 1
fi

printf 'ok: %s shell scripts (%s bash, %s sh, %s zsh)\n' \
    "$total" "$checked_bash" "$checked_sh" "$checked_zsh"

#!/usr/bin/env bash

set -euo pipefail

# DOTFILES_ROOT points the installer at another repo tree. The fixture in
# tests/install.test.sh uses it to install a throwaway manifest.
repo_root=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
repo_root=${DOTFILES_ROOT:-$repo_root}

os=$(uname -s)
case "$os" in
    Darwin)
        manifest="$repo_root/MAC.manifest"
        ;;
    Linux)
        manifest="$repo_root/LINUX.manifest"
        ;;
    *)
        echo "Unsupported operating system: $os" >&2
        exit 1
        ;;
esac

if [ ! -f "$manifest" ]; then
    echo "Manifest not found for $os: $manifest" >&2
    exit 1
fi

: "${HOME:?HOME is not set}"

env_file="$repo_root/.env.local"
if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") [application ...]

Install all manifest entries when no applications are provided.
When applications are provided, only install entries whose source starts with
that top-level directory, for example: $(basename "$0") zsh git kitty

Sources ending in .tmpl are rendered to regular files with {{ VAR }} values
from the environment or .env.local.
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

# Space-separated so the script also runs on macOS's bash 3.2, where an empty
# array trips "set -u".
requested_apps=$*
matched_apps=

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_requested_application() {
    [ -z "$requested_apps" ] && return 0

    app_name=${1%%/*}
    case " $requested_apps " in
        *" $app_name "*)
            matched_apps="$matched_apps $app_name"
            return 0
            ;;
    esac

    return 1
}

expand_destination() {
    # The tilde is a literal manifest destination prefix to match, not an
    # unexpanded home path, so expanding it here would be wrong.
    # shellcheck disable=SC2088
    case "$1" in
        '~')
            printf '%s\n' "$HOME"
            ;;
        '~/'*)
            printf '%s\n' "$HOME/${1#\~/}"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

render_template() {
    template_path=$1
    dest_path=$2
    tmp_path=$(mktemp "$dest_path.tmp.XXXXXX") || return 1

    if awk '
        {
            line = $0
            while (match(line, /\{\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}\}/)) {
                token = substr(line, RSTART, RLENGTH)
                name = token
                sub(/^\{\{[[:space:]]*/, "", name)
                sub(/[[:space:]]*\}\}$/, "", name)

                if (!(name in ENVIRON)) {
                    printf "WARN: missing template variable: %s\n", name > "/dev/stderr"
                    missing = 1
                    value = ""
                } else {
                    value = ENVIRON[name]
                }

                line = substr(line, 1, RSTART - 1) value substr(line, RSTART + RLENGTH)
            }
            print line
        }
        END { exit missing ? 1 : 0 }
    ' "$template_path" > "$tmp_path"; then
        mv "$tmp_path" "$dest_path"
    else
        rm -f "$tmp_path"
        return 1
    fi
}

install_entry() {
    source_path=$1
    dest_path=$2

    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
        echo "WARN: source missing: ${source_path#"$repo_root"/}" >&2
        return
    fi

    if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
        echo "SKIP: $dest_path already exists"
        return
    fi

    mkdir -p "$(dirname "$dest_path")"

    case "$source_path" in
        *.tmpl)
            if render_template "$source_path" "$dest_path"; then
                echo "RENDER: $dest_path <- $source_path"
            else
                echo "WARN: failed to render $dest_path" >&2
            fi
            ;;
        *)
            if ln -s "$source_path" "$dest_path"; then
                echo "LINK: $dest_path -> $source_path"
            else
                echo "WARN: failed to link $dest_path" >&2
            fi
            ;;
    esac
}

echo "Using manifest: $manifest"
if [ -n "$requested_apps" ]; then
    echo "Installing applications: $requested_apps"
else
    echo "Installing all applications"
fi
echo

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line=$(trim "$raw_line")

    case "$line" in
        ''|'#'*)
            continue
            ;;
    esac

    # Split the manifest entry at the first "|"; without one, dest_entry stays empty.
    # ${line%%|*} keeps everything before it; ${line#*|} keeps everything after it.
    source_entry=$(trim "${line%%|*}")
    dest_entry=
    case "$line" in
        *'|'*)
            dest_entry=$(trim "${line#*|}")
            ;;
    esac

    if [ -z "$source_entry" ] || [ -z "$dest_entry" ]; then
        echo "WARN: invalid manifest line: $raw_line" >&2
        continue
    fi

    if ! is_requested_application "$source_entry"; then
        continue
    fi

    case "$source_entry|$dest_entry" in
        */'*|'*/'*')
            # "dir/*|dest/*" installs each entry of dir as dest/<name>.
            # A missing or empty dir leaves the literal "*", reported as a missing source.
            dest_dir=$(expand_destination "${dest_entry%/\*}")
            for source_path in "$repo_root/${source_entry%/\*}"/*; do
                install_entry "$source_path" "$dest_dir/${source_path##*/}"
            done
            ;;
        *'*'*)
            echo "WARN: wildcard must be a trailing /* on both sides: $raw_line" >&2
            ;;
        *)
            install_entry "$repo_root/$source_entry" "$(expand_destination "$dest_entry")"
            ;;
    esac
done < "$manifest"

for requested_app in $requested_apps; do
    case " $matched_apps " in
        *" $requested_app "*) ;;
        *) echo "WARN: no manifest entries for application: $requested_app" >&2 ;;
    esac
done

echo
echo "Done."

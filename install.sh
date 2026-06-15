#!/usr/bin/env bash

set -euo pipefail

script_dir=$(dirname "$0")
repo_root=$(CDPATH= cd "$script_dir" && pwd -P) || exit 1

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

requested_apps=("$@")
matched_apps=()

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

application_name() {
    case "$1" in
        */*)
            printf '%s\n' "${1%%/*}"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

is_requested_application() {
    [ "${#requested_apps[@]}" -eq 0 ] && return 0

    app_name=$(application_name "$1")
    for requested_app in "${requested_apps[@]}"; do
        if [ "$app_name" = "$requested_app" ]; then
            matched_apps+=("$requested_app")
            return 0
        fi
    done

    return 1
}

expand_destination() {
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

echo "Using manifest: $manifest"
if [ "${#requested_apps[@]}" -gt 0 ]; then
    echo "Installing applications: ${requested_apps[*]}"
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

    case "$line" in
        *'|'*)
            # Split the manifest entry at the first "|".
            # ${line%%|*} keeps everything before it; ${line#*|} keeps everything after it.
            source_entry=$(trim "${line%%|*}")
            dest_entry=$(trim "${line#*|}")
            ;;
        *)
            echo "WARN: invalid manifest line: $raw_line" >&2
            continue
            ;;
    esac

    if [ -z "$source_entry" ] || [ -z "$dest_entry" ]; then
        echo "WARN: invalid manifest line: $raw_line" >&2
        continue
    fi

    if ! is_requested_application "$source_entry"; then
        continue
    fi

    source_path="$repo_root/$source_entry"
    dest_path=$(expand_destination "$dest_entry")

    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
        echo "WARN: source missing: $source_entry" >&2
        continue
    fi

    if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
        echo "SKIP: $dest_path already exists"
        continue
    fi

    parent_dir=$(dirname "$dest_path")
    mkdir -p "$parent_dir"

    case "$source_entry" in
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
done < "$manifest"

for requested_app in "${requested_apps[@]}"; do
    found_app=false
    for matched_app in "${matched_apps[@]}"; do
        if [ "$requested_app" = "$matched_app" ]; then
            found_app=true
            break
        fi
    done

    if [ "$found_app" = false ]; then
        echo "WARN: no manifest entries for application: $requested_app" >&2
    fi
done

echo
echo "Done."

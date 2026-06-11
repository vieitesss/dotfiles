#!/usr/bin/env bash

set -euo pipefail

repo="neovim/neovim"
tag="nightly"
install_dir="${HOME}/.local/opt/nvim-nightly"
link_path="${HOME}/.local/bin/nvim"
force_link=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--tag TAG] [--install-dir PATH] [--link PATH] [--force-link]

Download and install the official Neovim release tarball for this machine.
Defaults to the nightly release.

Options:
  --tag TAG           GitHub release tag to install (default: nightly)
  --install-dir PATH  Install directory (default: ~/.local/opt/nvim-nightly)
  --link PATH         Symlink to create/update (default: ~/.local/bin/nvim)
  --force-link        Replace an existing non-managed symlink or file at --link
  -h, --help          Show this help
EOF
}

expand_path() {
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

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)
            tag="${2:?missing value for --tag}"
            shift 2
            ;;
        --install-dir)
            install_dir=$(expand_path "${2:?missing value for --install-dir}")
            shift 2
            ;;
        --link)
            link_path=$(expand_path "${2:?missing value for --link}")
            shift 2
            ;;
        --force-link)
            force_link=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

require_command uname
require_command tar
require_command mktemp

if command -v curl >/dev/null 2>&1; then
    downloader="curl"
elif command -v wget >/dev/null 2>&1; then
    downloader="wget"
else
    echo "Required command not found: curl or wget" >&2
    exit 1
fi

os=$(uname -s)
arch=$(uname -m)

case "$os" in
    Darwin)
        os_part="macos"
        ;;
    Linux)
        os_part="linux"
        ;;
    *)
        echo "Unsupported operating system: $os" >&2
        exit 1
        ;;
esac

case "$arch" in
    x86_64|amd64)
        arch_part="x86_64"
        ;;
    arm64|aarch64)
        arch_part="arm64"
        ;;
    *)
        echo "Unsupported architecture: $arch" >&2
        exit 1
        ;;
esac

asset="nvim-${os_part}-${arch_part}.tar.gz"
url="https://github.com/${repo}/releases/download/${tag}/${asset}"

tmp_dir=$(mktemp -d)
archive="${tmp_dir}/${asset}"
staging_dir="${tmp_dir}/nvim"
backup_dir="${install_dir}.previous"

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

echo "Detected: ${os}/${arch}"
echo "Release: ${repo}@${tag}"
echo "Asset: ${asset}"
echo "Download: ${url}"

if [ "$downloader" = "curl" ]; then
    curl -fL --progress-bar -o "$archive" "$url"
else
    wget -O "$archive" "$url"
fi

mkdir -p "$staging_dir"
tar -xzf "$archive" -C "$staging_dir" --strip-components=1

if [ ! -x "${staging_dir}/bin/nvim" ]; then
    echo "Downloaded archive did not contain executable bin/nvim" >&2
    exit 1
fi

if [ "$os" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
    xattr -cr "$staging_dir" 2>/dev/null || true
fi

mkdir -p "$(dirname "$install_dir")"
rm -rf "$backup_dir"

if [ -e "$install_dir" ] || [ -L "$install_dir" ]; then
    mv "$install_dir" "$backup_dir"
fi

if ! mv "$staging_dir" "$install_dir"; then
    if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
        mv "$backup_dir" "$install_dir"
    fi
    echo "Install failed; previous install restored" >&2
    exit 1
fi

mkdir -p "$(dirname "$link_path")"
expected_target="${install_dir}/bin/nvim"

if [ -L "$link_path" ]; then
    current_target=$(readlink "$link_path")
    if [ "$current_target" = "$expected_target" ] || [ "$force_link" = true ]; then
        ln -sfn "$expected_target" "$link_path"
        echo "LINK: ${link_path} -> ${expected_target}"
    else
        echo "SKIP: ${link_path} points to ${current_target}"
        echo "      Use --force-link to replace it with ${expected_target}"
    fi
elif [ -e "$link_path" ]; then
    if [ "$force_link" = true ]; then
        rm -rf "$link_path"
        ln -s "$expected_target" "$link_path"
        echo "LINK: ${link_path} -> ${expected_target}"
    else
        echo "SKIP: ${link_path} already exists and is not a symlink"
        echo "      Use --force-link to replace it with ${expected_target}"
    fi
else
    ln -s "$expected_target" "$link_path"
    echo "LINK: ${link_path} -> ${expected_target}"
fi

version=$("${install_dir}/bin/nvim" --version | head -n 1)
echo "INSTALLED: ${version}"
echo "PATH hint: ensure $(dirname "$link_path") is before package-manager bins if you want nightly by default."

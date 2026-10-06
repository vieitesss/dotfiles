#!/usr/bin/env bash

# Fixture for install.sh. It installs a throwaway manifest into a throwaway
# HOME and checks the destination cases the installer promises to handle:
# wildcard entries, missing sources, existing destinations and dangling
# destinations.
#
# install.sh is invoked with no application arguments on purpose: that is the
# path where macOS's bash 3.2 trips "unbound variable" if an empty array is
# expanded under `set -u`, so running this fixture under /bin/bash on macOS
# keeps that regression from coming back.

set -uo pipefail

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)

# macOS's /bin/bash is 3.2; prefer it so the fixture runs on the oldest shell
# the installer supports.
if [ -x /bin/bash ]; then
    install_bash=/bin/bash
else
    install_bash=bash
fi

failed=0

pass() { printf 'ok: %s\n' "$1"; }

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failed=1
}

expect() {
    label=$1
    shift
    if "$@"; then
        pass "$label"
    else
        fail "$label"
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

root="$work/repo"
home="$work/home"
mkdir -p "$root" "$home"

# Fixture sources, referenced from the manifest below.
mkdir -p "$root/wildcard" "$root/dirs"
printf 'alpha\n' > "$root/wildcard/alpha"
printf 'beta\n' > "$root/wildcard/beta"
printf 'hidden\n' > "$root/wildcard/.hidden"
mkdir "$root/wildcard/subdir"
printf 'existing\n' > "$root/dirs/existing"
printf 'plain\n' > "$root/dirs/plain"
printf 'fresh\n' > "$root/dirs/fresh"

# install.sh picks the manifest by OS, so both names carry the same entries.
cat > "$root/MAC.manifest" <<'EOF'
# comment lines and blank lines are ignored

wildcard/*|~/wild/*
missing/source|~/.config/missing
dirs/existing|~/.config/existing
dirs/plain|~/.config/dangling
dirs/fresh|~/.config/fresh
EOF
cp "$root/MAC.manifest" "$root/LINUX.manifest"

# Pre-existing destinations: a real file and a dangling symlink.
mkdir -p "$home/.config"
printf 'keep me\n' > "$home/.config/existing"
ln -s "$work/nowhere" "$home/.config/dangling"

output=$(env DOTFILES_ROOT="$root" HOME="$home" "$install_bash" "$repo_root/install.sh" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
    pass "install.sh exits 0 ($("$install_bash" --version | head -1))"
else
    fail "install.sh exited $rc"
fi

# Wildcard entry: every visible entry is linked into the destination directory,
# hidden entries are not.
expect "wildcard links dir entry alpha" \
    test "$(readlink "$home/wild/alpha" 2>/dev/null)" = "$root/wildcard/alpha"
expect "wildcard links dir entry beta" \
    test "$(readlink "$home/wild/beta" 2>/dev/null)" = "$root/wildcard/beta"
expect "wildcard links subdirectories" \
    test "$(readlink "$home/wild/subdir" 2>/dev/null)" = "$root/wildcard/subdir"
expect "wildcard skips hidden entries" test ! -e "$home/wild/.hidden" -a ! -L "$home/wild/.hidden"

# Missing source: warned about, install continues.
case "$output" in
    *"WARN: source missing: missing/source"*) pass "missing source is reported" ;;
    *) fail "missing source is not reported" ;;
esac
expect "missing source creates no destination" \
    test ! -e "$home/.config/missing" -a ! -L "$home/.config/missing"

# Existing destination: skipped, and the file is left exactly as it was.
case "$output" in
    *"SKIP: $home/.config/existing already exists"*) pass "existing destination is reported as skipped" ;;
    *) fail "existing destination is not reported as skipped" ;;
esac
if [ -L "$home/.config/existing" ]; then
    fail "existing destination was replaced by a symlink"
elif [ "$(cat "$home/.config/existing")" = "keep me" ]; then
    pass "existing destination is left unchanged"
else
    fail "existing destination content changed"
fi

# Dangling destination: a symlink to nowhere still counts as existing.
case "$output" in
    *"SKIP: $home/.config/dangling already exists"*) pass "dangling destination is reported as skipped" ;;
    *) fail "dangling destination is not reported as skipped" ;;
esac
if [ -L "$home/.config/dangling" ] \
    && [ "$(readlink "$home/.config/dangling")" = "$work/nowhere" ]; then
    pass "dangling destination is left pointing where it did"
else
    fail "dangling destination was changed"
fi

# Remaining manifest entry was installed normally.
expect "regular entry is linked" \
    test "$(readlink "$home/.config/fresh" 2>/dev/null)" = "$root/dirs/fresh"

if [ "$failed" -ne 0 ]; then
    echo
    echo "--- install.sh output ---"
    printf '%s\n' "$output"
    exit 1
fi

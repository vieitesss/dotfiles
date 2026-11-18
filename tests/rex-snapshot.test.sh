#!/bin/sh
# Test for rex/snapshot.lua. Run: sh tests/rex-snapshot.test.sh
#
# The module needs Rex's Lua, so the cases run through `rex do`. They cover
# the part that touches no session: rewriting each command for restore.
set -eu

if ! command -v rex >/dev/null 2>&1; then
    printf 'skip: %s (rex is not installed)\n' "$0"
    exit 0
fi

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

out=$(REX_DB="$tmp/db.json" REX_CONFIG_DIR="$repo_root/rex" \
    rex do "$repo_root/tests/rex-snapshot.test.lua" 2>"$tmp/stderr") || {
    printf 'FAIL: %s\n' "$out" >&2
    cat "$tmp/stderr" >&2
    exit 1
}
[ "$out" = ok ] || {
    printf 'FAIL: %s\n' "$out" >&2
    exit 1
}
printf 'ok: %s\n' "$0"

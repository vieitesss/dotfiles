#!/bin/sh
# Test for rex/db.lua and rex/last_session.lua. Run: sh tests/rex-db.test.sh
#
# The modules need Rex's Lua (rex.json, rex.exec), so the cases run through
# `rex do` against a throwaway database file. They read and write only that
# file; they never touch a session.
set -eu

if ! command -v rex >/dev/null 2>&1; then
    printf 'skip: %s (rex is not installed)\n' "$0"
    exit 0
fi

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The corrupt-file case logs a warning on stderr; only stdout is the verdict.
out=$(REX_DB="$tmp/state/db.json" REX_CONFIG_DIR="$repo_root/rex" \
    rex do "$repo_root/tests/rex-db.test.lua" 2>"$tmp/stderr") || {
    printf 'FAIL: %s\n' "$out" >&2
    cat "$tmp/stderr" >&2
    exit 1
}
[ "$out" = ok ] || {
    printf 'FAIL: %s\n' "$out" >&2
    exit 1
}
printf 'ok: %s\n' "$0"

#!/bin/sh
# Test for rex/db.lua and rex/last_session.lua. Run: sh tests/rex-db.test.sh
#
# The modules need Rex's Lua (rex.json, rex.exec), so the cases run through
# `rex do` against a throwaway database file. Binding tests load only the
# last-session config block with a fake Rex; no live session actions run.
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
# Writers at the same time must not lose each other's keys: five processes
# each set their own key twenty times against one database.
cat >"$tmp/writer.lua" <<'LUA'
package.path = os.getenv("REX_CONFIG_DIR") .. "/?.lua;" .. package.path
local db = require("db")
for n = 1, 20 do db.set(os.getenv("WRITER"), n) end
LUA
for w in 1 2 3 4 5; do
    WRITER="w$w" REX_DB="$tmp/race/db.json" REX_CONFIG_DIR="$repo_root/rex" \
        rex do "$tmp/writer.lua" >/dev/null 2>&1 &
done
wait
cat >"$tmp/reader.lua" <<'LUA'
package.path = os.getenv("REX_CONFIG_DIR") .. "/?.lua;" .. package.path
local db = require("db")
for w = 1, 5 do
  assert(db.get("w" .. w) == 20, "concurrent writers lost w" .. w)
end
LUA
REX_DB="$tmp/race/db.json" REX_CONFIG_DIR="$repo_root/rex" rex do "$tmp/reader.lua"

printf 'ok: %s\n' "$0"
